import asyncio
import functools
from abc import ABC
from abc import ABCMeta
from abc import abstractmethod
from urllib.parse import urljoin

from httpx import AsyncClient
from httpx import Client as SyncClient
from ipfs_client.main import AsyncIPFSClient

from snapshotter.settings.config import settings
from snapshotter.utils.default_logger import logger
from snapshotter.utils.models.data_models import PreloaderResult
from snapshotter.utils.models.message_models import EpochBase
from snapshotter.utils.models.message_models import SnapshotProcessMessage
from snapshotter.utils.models.message_models import TelegramEpochProcessingReportMessage
from snapshotter.utils.models.message_models import TelegramMessage
from snapshotter.utils.models.message_models import TelegramSnapshotterReportMessage
from snapshotter.utils.rpc import RpcHelper

# setup logger
helper_logger = logger.bind(module='Callback|Helpers')


def misc_notification_callback_result_handler(fut: asyncio.Future):
    """
    Handles the result of a callback or notification.

    Args:
        fut (asyncio.Future): The future object representing the callback or notification.

    Returns:
        None
    """
    try:
        r = fut.result()
    except Exception as e:
        if settings.logs.trace_enabled:
            logger.opt(exception=True).error(
                'Exception while sending callback or notification: {}', e,
            )
        else:
            logger.error('Exception while sending callback or notification: {}', e)
    else:
        logger.debug('Callback or notification result:{}', r)


def sync_notification_callback_result_handler(f: functools.partial):
    """
    Handles the result of a synchronous notification callback.

    Args:
        f (functools.partial): The function to handle.

    Returns:
        None
    """
    try:
        result = f()
    except Exception as exc:
        if settings.logs.trace_enabled:
            logger.opt(exception=True).error(
                'Exception while sending callback or notification: {}', exc,
            )
        else:
            logger.error('Exception while sending callback or notification: {}', exc)
    else:
        logger.debug('Callback or notification result:{}', result)


async def send_telegram_notification_async(client: AsyncClient, message: TelegramMessage):
    """
    Sends an asynchronous Telegram notification for reporting issues.

    This function checks if Telegram reporting is configured, and then sends the appropriate
    message based on its type (epoch processing issue or snapshotter issue).

    Args:
        client (AsyncClient): The async HTTP client to use for sending notifications.
        message (TelegramMessage): The message to send as a Telegram notification.

    Returns:
        None
    """

    if not settings.reporting.telegram_url or not settings.reporting.telegram_chat_id:
        return

    if isinstance(message, TelegramEpochProcessingReportMessage):
        endpoint = '/reportEpochProcessingIssue'
    elif isinstance(message, TelegramSnapshotterReportMessage):
        endpoint = '/reportSnapshotIssue'
    else:
        helper_logger.error(
            f'Unsupported telegram message type: {type(message)} - message not sent',
        )
        return

    f = asyncio.ensure_future(
        client.post(
            url=urljoin(settings.reporting.telegram_url, endpoint),
            json=message.dict(),
        ),
    )
    f.add_done_callback(misc_notification_callback_result_handler)


def send_telegram_notification_sync(client: SyncClient, message: TelegramMessage):
    """
    Sends a synchronous Telegram notification for reporting issues.

    This function checks if Telegram reporting is configured, and then sends the appropriate
    message based on its type (epoch processing issue or snapshotter issue).

    Args:
        client (SyncClient): The synchronous HTTP client to use for sending notifications.
        message (TelegramMessage): The message to send as a Telegram notification.

    Returns:
        None
    """

    if not settings.reporting.telegram_url or not settings.reporting.telegram_chat_id:
        return

    if isinstance(message, TelegramEpochProcessingReportMessage):
        endpoint = '/reportEpochProcessingIssue'
    elif isinstance(message, TelegramSnapshotterReportMessage):
        endpoint = '/reportSnapshotIssue'
    else:
        helper_logger.error(
            f'Unsupported telegram message type: {type(message)} - message not sent',
        )
        return

    f = functools.partial(
        client.post,
        url=urljoin(settings.reporting.telegram_url, endpoint),
        json=message.dict(),
    )
    sync_notification_callback_result_handler(f)


class GenericProcessor(ABC):
    __metaclass__ = ABCMeta

    def __init__(self):
        pass

    @abstractmethod
    async def compute(
        self,
        msg_obj: SnapshotProcessMessage,
        rpc_helper: RpcHelper,
        anchor_rpc_helper: RpcHelper,
        ipfs_reader: AsyncIPFSClient,
        protocol_state_contract,
        preloader_results: dict,
    ):
        pass


class GenericPreloader(ABC):
    """
    Abstract base class for preloaders.
    """
    __metaclass__ = ABCMeta

    def __init__(self):
        pass

    @abstractmethod
    async def compute(
        self,
        epoch: EpochBase,
        rpc_helper: RpcHelper,
    ) -> PreloaderResult:
        """
        Abstract method to compute preload data.

        Args:
            epoch (EpochBase): The epoch message.
            redis_conn (aioredis.Redis): Redis connection.
            rpc_helper (RpcHelper): RPC helper instance.
        """
        pass

    @abstractmethod
    async def cleanup(self):
        """
        Abstract method to clean up resources.
        """
        pass
