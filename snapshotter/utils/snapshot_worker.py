import importlib
import json
import time
import asyncio
from typing import Optional

from ipfs_client.main import AsyncIPFSClient
from ipfs_client.main import AsyncIPFSClientSingleton
from httpx import AsyncClient
from httpx import AsyncHTTPTransport
from httpx import Limits
from httpx import Timeout

from snapshotter.settings.config import projects_config
from snapshotter.settings.config import settings
from snapshotter.utils.callback_helpers import send_telegram_notification_async
from snapshotter.utils.generic_worker import GenericAsyncWorker
from snapshotter.utils.models.data_models import SnapshotterIssue
from snapshotter.utils.models.data_models import SnapshotterReportState
from snapshotter.utils.models.data_models import SnapshotterStatus
from snapshotter.utils.models.message_models import SnapshotProcessMessage
from snapshotter.utils.models.message_models import TelegramSnapshotterReportMessage
from snapshotter.utils.slot_selection_tracker import SlotSelectionTracker


class SnapshotAsyncWorker(GenericAsyncWorker):
    _ipfs_singleton: AsyncIPFSClientSingleton
    _ipfs_writer_client: AsyncIPFSClient
    _ipfs_reader_client: AsyncIPFSClient
    _telegram_httpx_client: AsyncClient

    def __init__(self):
        """
        Initializes a SnapshotAsyncWorker object.

        Args:
            name (str): The name of the worker.
            **kwargs: Additional keyword arguments to be passed to the AsyncWorker constructor.
        """
        self._project_calculation_mapping = {}
        super().__init__()
        self._task_types = []
        for project_config in projects_config:
            task_type = project_config.project_type
            self._task_types.append(task_type)
        self.status = SnapshotterStatus(projects=[])
        self.last_notification_time = 0
        self.notification_cooldown = settings.reporting.notification_cooldown
        self._slot_tracker = SlotSelectionTracker()
        self._consecutive_selection_failures = []  # List of epoch_ids where selected but failed
        self._alert_sent = False

    async def _handle_selection_failure(self, epoch_id: int):
        """
        Handle a failure when slot was selected but processing failed.
        
        Tracks consecutive failures and sends alert after 3 consecutive selected-but-failed epochs.
        """
        self._consecutive_selection_failures.append(epoch_id)
        
        # Keep only recent failures for tracking
        if len(self._consecutive_selection_failures) > 10:
            self._consecutive_selection_failures = self._consecutive_selection_failures[-10:]
        
        self.logger.warning(
            f"Slot selected for epoch {epoch_id} but processing failed. "
            f"Consecutive selection failures: {len(self._consecutive_selection_failures)}"
        )
        
        # Alert if 3 consecutive selected epochs failed
        if len(self._consecutive_selection_failures) >= 3 and not self._alert_sent:
            error_message = (
                f"3 consecutive epochs where slot was selected but processing failed: "
                f"{self._consecutive_selection_failures[-3:]}"
            )
            self.logger.error(error_message)
            
            # Send telegram notification
            if settings.reporting.telegram_url and settings.reporting.telegram_chat_id:
                await send_telegram_notification_async(
                    client=self._telegram_httpx_client,
                    message=TelegramSnapshotterReportMessage(
                        chatId=settings.reporting.telegram_chat_id,
                        message_thread_id=settings.reporting.telegram_message_thread_id,
                        slotId=settings.slot_id,
                        issue=SnapshotterIssue(
                            instanceID=settings.instance_id,
                            issueType=SnapshotterReportState.UNHEALTHY_EPOCH_PROCESSING.value,
                            projectID='',
                            epochId=str(epoch_id),
                            timeOfReporting=str(time.time()),
                            extra=json.dumps({'issueDetails': error_message}),
                        ),
                    ),
                )
            
            self._alert_sent = True
    
    async def _handle_selection_success(self, epoch_id: int):
        """
        Handle successful processing when slot was selected.
        
        Resets consecutive failure tracking.
        """
        self.logger.info(
            f"Slot selected for epoch {epoch_id} and processing succeeded. "
            f"Resetting consecutive failure count (was: {len(self._consecutive_selection_failures)})"
        )
        self._consecutive_selection_failures = []
        self._alert_sent = False

    def _gen_project_id(self, task_type: str, data_source: Optional[str] = None, primary_data_source: Optional[str] = None):
        """
        Generates a project ID based on the given task type, data source, and primary data source.

        Args:
            task_type (str): The type of task.
            data_source (Optional[str], optional): The data source. Defaults to None.
            primary_data_source (Optional[str], optional): The primary data source. Defaults to None.

        Returns:
            str: The generated project ID.
        """
        if not data_source:
            # For generic use cases that don't have a data source like block details
            project_id = f'{task_type}:{settings.namespace}'
        else:
            if primary_data_source:
                project_id = f'{task_type}:{primary_data_source.lower()}_{data_source.lower()}:{settings.namespace}'
            else:
                project_id = f'{task_type}:{data_source.lower()}:{settings.namespace}'
        return project_id

    async def _process(self, msg_obj: SnapshotProcessMessage, task_type: str, preloader_results: dict):
        """
        Processes the given SnapshotProcessMessage object in bulk mode.

        Args:
            msg_obj (SnapshotProcessMessage): The message object to process.
            task_type (str): The type of task to perform.

        Raises:
            Exception: If an error occurs while processing the message.

        Returns:
            None
        """
        try:
            task_processor = self._project_calculation_mapping[task_type]
            
            snapshots = await task_processor.compute(
                msg_obj=msg_obj,
                rpc_helper=self._rpc_helper,
                anchor_rpc_helper=self._anchor_rpc_helper,
                ipfs_reader=self._ipfs_reader_client,
                protocol_state_contract=self.protocol_state_contract,
                preloader_results=preloader_results,
                slot_tracker=self._slot_tracker,
            )

            if not snapshots:
                # Check if we were selected - empty return after selection is a failure
                selection_status = self._slot_tracker.get_last_selection()
                if selection_status and selection_status.get('was_selected') and selection_status.get('epoch_id') == msg_obj.epochId:
                    # Selected but compute returned empty - this is a failure
                    error_msg = f"Slot {selection_status['slot_id']} selected for epoch {msg_obj.epochId} but compute returned no data"
                    self.logger.error(error_msg)
                    raise Exception(error_msg)
                else:
                    # Not selected - empty return is normal
                    self.logger.debug(
                        'No snapshot data for: {}, skipping...', msg_obj,
                    )

        except Exception as e:
            self.logger.opt(exception=True).error(
                'Exception processing callback for epoch: {}, Error: {},'
                'sending failure notifications', msg_obj, e,
            )
            raise

        else:

            for project_data_source, snapshot in snapshots:
                data_sources = project_data_source.split('_')
                if len(data_sources) == 1:
                    data_source = data_sources[0]
                    primary_data_source = None
                else:
                    primary_data_source, data_source = data_sources

                project_id = self._gen_project_id(
                    task_type=task_type, data_source=data_source, primary_data_source=primary_data_source,
                )
                
                try:
                    await self._commit_payload(
                        task_type=task_type,
                        _ipfs_writer_client=self._ipfs_writer_client,
                        project_id=project_id,
                        epoch=msg_obj,
                        snapshot=snapshot
                    )
                except Exception as e:
                    self.logger.opt(exception=True).error(
                        'Exception committing snapshot payload for epoch: {}, Error: {},'
                        'sending failure notifications', msg_obj, e,
                    )
                    raise

    async def process_task(self, msg_obj: SnapshotProcessMessage, task_type: str, preloader_results: dict):
        """
        Process a SnapshotProcessMessage object for a given task type.

        Args:
            msg_obj (SnapshotProcessMessage): The message object to process.
            task_type (str): The type of task to perform.

        Returns:
            None
        """
        self.logger.debug(
            'Processing callback: {}', msg_obj,
        )
        if task_type not in self._project_calculation_mapping:
            self.logger.error(
                (
                    'No project calculation mapping found for task type'
                    f' {task_type}. Skipping...'
                ),
            )
            return

        epoch_id = msg_obj.epochId
        processing_failed = False

        try:

            self.logger.debug(
                'Got epoch to process for {}: {}',
                task_type, msg_obj,
            )

            await self._process(
                msg_obj=msg_obj,
                task_type=task_type,
                preloader_results=preloader_results,
            )
        except Exception as e:
            processing_failed = True
            self.logger.error(f"Error processing SnapshotProcessMessage: {msg_obj} for task type: {task_type} - Error: {e}")
            await self.handle_missed_snapshot(
                error=e,
                epoch_id=str(msg_obj.epochId),
                project_id=self._gen_project_id(
                    task_type=task_type,
                ),
            )
        else:
            # reset consecutive missed snapshots counter
            self.status.consecutiveMissedSubmissions = 0
            self.status.totalSuccessfulSubmissions += 1
        
        # After processing completes (success or failure), check slot selection status
        selection_status = self._slot_tracker.get_last_selection()
        if selection_status and selection_status.get('was_selected') and selection_status.get('epoch_id') == epoch_id:
            # This slot was selected for this epoch
            if processing_failed:
                # Selected but processing failed - track consecutive failures
                await self._handle_selection_failure(epoch_id)
            else:
                # Selected and processing succeeded - reset failures
                await self._handle_selection_success(epoch_id)
        # If not selected, don't affect failure tracking

    async def _init_project_calculation_mapping(self):
        """
        Initializes the project calculation mapping by generating a dictionary that maps project types to their corresponding
        calculation classes.

        Raises:
            Exception: If a duplicate project type is found in the projects configuration.
        """
        if self._project_calculation_mapping != {}:
            return
        # Generate project function mapping
        self._project_calculation_mapping = dict()
        for project_config in projects_config:
            key = project_config.project_type
            if key in self._project_calculation_mapping:
                raise Exception('Duplicate project type found')
            module = importlib.import_module(project_config.processor.module)
            class_ = getattr(module, project_config.processor.class_name)
            self._project_calculation_mapping[key] = class_()

    async def _init_ipfs_client(self):
        """
        Initializes the IPFS client by creating a singleton instance of AsyncIPFSClientSingleton
        and initializing its sessions. The write and read clients are then assigned to instance variables.
        """
        self._ipfs_reader_client = None
        self._ipfs_writer_client = None
        if not settings.ipfs.url:
            return
        self._ipfs_singleton = AsyncIPFSClientSingleton(settings.ipfs)
        await self._ipfs_singleton.init_sessions()
        self._ipfs_writer_client = self._ipfs_singleton._ipfs_write_client
        self._ipfs_reader_client = self._ipfs_singleton._ipfs_read_client

    async def _init_telegram_client(self):
        """
        Initializes the Telegram client.
        """
        self._telegram_httpx_client = AsyncClient(
            base_url=settings.reporting.telegram_url,
            timeout=Timeout(timeout=5.0),
            follow_redirects=False,
            transport=AsyncHTTPTransport(limits=Limits(max_connections=100, max_keepalive_connections=50, keepalive_expiry=None)),
        )

    async def init_worker(self):
        """
        Initializes the worker by initializing project calculation mapping, IPFS client, and other necessary components.
        """
        if not self.initialized:
            await self._init_project_calculation_mapping()
            await self._init_ipfs_client()
            await self._init_telegram_client()
            await self.init()

    async def handle_missed_snapshot(self, error: Exception, epoch_id: str, project_id: str):
        """
        Handles missed snapshots by sending failure notifications and updating the status.
        """
        self.logger.error(f"Missed snapshot for epoch: {epoch_id}, project_id: {project_id} - Error: {error}")
        self.status.totalMissedSubmissions += 1
        self.status.consecutiveMissedSubmissions += 1
        await self._send_failure_notifications(error=error, epoch_id=epoch_id, project_id=project_id)

    async def _send_failure_notifications(
        self,
        error: Exception,
        epoch_id: str,
        project_id: str,
    ):
        """
        Sends failure notifications for missed snapshots.

        Args:
            error (Exception): The error that occurred.
            epoch_id (str): The ID of the epoch that missed the snapshot.
            project_id (str): The ID of the project that missed the snapshot.
        """
        if (int(time.time()) - self.last_notification_time) >= self.notification_cooldown and \
            (settings.reporting.telegram_url and settings.reporting.telegram_chat_id):

            if not self._telegram_httpx_client:
                self.logger.error('Telegram client not initialized')
                return

            try:
                notification_message = SnapshotterIssue(
                    instanceID=settings.instance_id,
                    issueType=SnapshotterReportState.MISSED_SNAPSHOT.value,
                    projectID=project_id,
                    epochId=str(epoch_id),
                    timeOfReporting=str(time.time()),
                    extra=json.dumps({'issueDetails': f'Error : {error}'}),
                )

                message_thread_id = settings.reporting.telegram_message_thread_id

                telegram_message = TelegramSnapshotterReportMessage(
                    chatId=settings.reporting.telegram_chat_id,
                    slotId=settings.slot_id,
                    message_thread_id=message_thread_id,
                    issue=notification_message,
                    status=self.status,
                )

                await send_telegram_notification_async(
                    client=self._telegram_httpx_client,
                    message=telegram_message,
                )

                self.last_notification_time = int(time.time())

            except Exception as e:
                self.logger.error(f"Error sending failure notifications: {e}")
