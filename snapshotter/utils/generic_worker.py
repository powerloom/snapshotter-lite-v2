import asyncio
import json
import time
from typing import Dict
from typing import Union
import grpclib
import sha3
import tenacity
from coincurve import PrivateKey
from eip712_structs import EIP712Struct
from eip712_structs import make_domain
from eip712_structs import String
from eip712_structs import Uint
from eth_utils.encoding import big_endian_to_int
from grpclib.client import Channel
from ipfs_cid import cid_sha256_hash
from ipfs_client.dag import IPFSAsyncClientError
from ipfs_client.main import AsyncIPFSClient
from pydantic import BaseModel
from tenacity import retry
from tenacity import retry_if_exception_type
from tenacity import stop_after_attempt
from tenacity import wait_random_exponential
from web3 import Web3

from snapshotter.settings.config import settings
from snapshotter.utils.default_logger import logger
from snapshotter.utils.file_utils import read_json_file
from snapshotter.utils.models.message_models import SnapshotProcessMessage
from snapshotter.utils.models.message_models import SnapshotSubmittedMessage
from snapshotter.utils.models.proto.snapshot_submission.submission_grpc import SubmissionStub
from snapshotter.utils.models.proto.snapshot_submission.submission_pb2 import Request
from snapshotter.utils.models.proto.snapshot_submission.submission_pb2 import SnapshotSubmission

from snapshotter.utils.rpc import RpcHelper

import grpclib
from snapshotter.version import __version__


class EIPRequest(EIP712Struct):
    slotId = Uint()
    deadline = Uint()
    snapshotCid = String()
    epochId = Uint()
    projectId = String()


def ipfs_upload_retry_state_callback(retry_state: tenacity.RetryCallState):
    """
    Callback function to handle retry attempts for IPFS uploads.

    Args:
        retry_state (tenacity.RetryCallState): The current state of the retry attempt.

    Returns:
        None
    """
    if retry_state and retry_state.outcome.failed:
        logger.warning(
            f'Encountered ipfs upload exception: {retry_state.outcome.exception()} | args: {retry_state.args}, kwargs:{retry_state.kwargs}',
        )


class GenericAsyncWorker:
    _rpc_helper: RpcHelper
    _anchor_rpc_helper: RpcHelper
    _grpc_channel: Channel
    _grpc_stub: SubmissionStub

    def __init__(self):
        """
        Initializes a GenericAsyncWorker instance.

        Args:
            name (str): The name of the worker.
            **kwargs: Additional keyword arguments to pass to the superclass constructor.
        """
        self._running_callback_tasks: Dict[str, asyncio.Task] = dict()
        self.protocol_state_contract = None

        self.protocol_state_contract_address = settings.protocol_state.address
        self.initialized = False
        self.logger = logger.bind(module='GenericAsyncWorker')

    def _notification_callback_result_handler(self, fut: asyncio.Future):
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
                    'Exception while sending callback or notification, Error: {}', e,
                )
            else:
                logger.error('Exception while sending callback or notification: {}', e)
        else:
            logger.debug('Callback or notification result:{}', r[0])

    async def _httpx_post_wrapper(self, url, req_json):
        exc = None
        try:
            r = await self._client.post(url=url, json=req_json)
        except Exception as e:
            exc = e
            r = None
        else:
            try:
                r = r.json()
            except:
                r = str(r)
        return r, exc, req_json['epochId'], req_json['projectId'], req_json['slotId']

    @retry(
        wait=wait_random_exponential(multiplier=1, max=10),
        stop=stop_after_attempt(5),
        retry=tenacity.retry_if_not_exception_type(IPFSAsyncClientError),
        after=ipfs_upload_retry_state_callback,
    )
    async def _upload_to_ipfs(self, snapshot: bytes, _ipfs_writer_client: AsyncIPFSClient):
        """
        Uploads a snapshot to IPFS using the provided AsyncIPFSClient.

        Args:
            snapshot (bytes): The snapshot to upload.
            _ipfs_writer_client (AsyncIPFSClient): The IPFS client to use for uploading.

        Returns:
            str: The CID of the uploaded snapshot.
        """
        snapshot_cid = await _ipfs_writer_client.add_bytes(snapshot)
        return snapshot_cid

    async def _send_submission_to_collector(self, snapshot_cid, epoch_id, project_id):
        self.logger.debug(
            'Sending submission to collector...',
        )
        request_, signature, current_block_hash = await self.generate_signature(snapshot_cid, epoch_id, project_id, settings.slot_id, settings.signer_private_key)

        request_msg = Request(
            slotId=request_['slotId'],
            deadline=request_['deadline'],
            snapshotCid=request_['snapshotCid'],
            epochId=request_['epochId'],
            projectId=request_['projectId'],
        )
        self.logger.debug(
            'Snapshot submission creation with request: {}', request_msg,
        )
        msg = SnapshotSubmission(request=request_msg, signature=signature.hex(), header=current_block_hash, dataMarket=settings.data_market, nodeVersion=__version__)
        self.logger.debug(
            'Snapshot submission created: {}', msg,
        )
        kwargs_simulation = {'simulation': False}
        if epoch_id == 0:
            kwargs_simulation['simulation'] = True
        try:
            await self.send_message(msg=msg, **kwargs_simulation)
        except Exception as e:
            if 'StreamTerminatedError' in str(e):  # Doing this because we get RetryError here not StreamTerminatedError
                pass  # fail silently as this is intended for the stream to be closed right after sending the message
            else:
                self.logger.error(
                    f'Probable exception in _send_submission_to_collector while sending snapshot to local collector {msg}: {e}',
                )
                raise
        else:
            self.logger.info('In _send_submission_to_collector successfully sent snapshot to local collector {msg}')

    @retry(
        wait=wait_random_exponential(multiplier=1, max=10),
        stop=stop_after_attempt(3),
        retry=retry_if_exception_type(Exception),
    )
    async def send_message(self, msg, simulation=False):
        """
        Sends a message to the collector, either as a simulation or a real submission.

        Args:
            msg (SnapshotSubmission): The message to send.
            simulation (bool, optional): Whether this is a simulation. Defaults to False.

        Raises:
            Exception: If failed to send the message.
        """
        try:
            response = await self._grpc_stub.SubmitSnapshot(msg)
            self.logger.debug(f'Sent message to local collector and received response: {response}')
        except grpclib.GRPCError as e:
            self.logger.error(f'gRPC error occurred while sending snapshot to local collector: {e}')
            raise
        except asyncio.CancelledError:
            self.logger.info('Task to send snapshot to local collector was asyncio cancelled!')
            raise
        except Exception as e:
            self.logger.error(f'Unexpected error occurred while sending snapshot to local collector: {e}')
            raise
        else:
            self.logger.info(f'Successfully submitted snapshot to local collector: {msg}')
            # write to a file on last successful submission to local collector
            with open('last_successful_submission.txt', 'w') as f:
                f.write(str(int(time.time())))
        
        return response

    async def _commit_payload(
            self,
            task_type: str,
            _ipfs_writer_client: AsyncIPFSClient,
            project_id: str,
            epoch: Union[
                SnapshotProcessMessage,
                SnapshotSubmittedMessage
            ],
            snapshot: BaseModel,
    ):
        """
        Commits the given snapshot to IPFS and sends messages to the event detector dispatch queues.

        Args:
            task_type (str): The type of task being committed.
            _ipfs_writer_client (AsyncIPFSClient): The IPFS client to use for uploading the snapshot.
            project_id (str): The ID of the project the snapshot belongs to.
            epoch (Union[SnapshotProcessMessage, SnapshotSubmittedMessage,
            SnapshotSubmittedMessageLite]): The epoch the snapshot belongs to.
            snapshot (BaseModel): The snapshot to commit.

        Returns:
            snapshot_cid (str): The CID of the uploaded snapshot.
        """
        # upload to IPFS
        snapshot_json = json.dumps(snapshot.dict(by_alias=True), sort_keys=True, separators=(',', ':'))
        snapshot_bytes = snapshot_json.encode('utf-8')
        try:
            if settings.ipfs.url:
                snapshot_cid = await self._upload_to_ipfs(snapshot_bytes, _ipfs_writer_client)
            else:
                snapshot_cid = cid_sha256_hash(snapshot_bytes)
        except Exception as e:
            self.logger.opt(exception=True).error(
                'Exception uploading snapshot to IPFS for epoch {}: {}, Error: {},'
                'sending failure notifications', epoch, snapshot, e,
            )
            raise
        else:
            # submit to collector
            try:
                await self._send_submission_to_collector(snapshot_cid, epoch.epochId, project_id)
            except Exception as e:
                self.logger.opt(exception=True).error(
                    'Exception submitting snapshot to collector for epoch {}: {}, Error: {},'
                    'sending failure notifications', epoch, snapshot, e,
                )
                raise
            else:
                return snapshot_cid

    async def _init_rpc_helper(self):
        """
        Initializes the RpcHelper objects for the worker and anchor chain, and sets up the protocol state contract.
        """
        self._rpc_helper = RpcHelper(rpc_settings=settings.rpc)
        self._anchor_rpc_helper = RpcHelper(rpc_settings=settings.powerloom_chain_rpc)

        self.protocol_state_contract = self._anchor_rpc_helper.get_current_node()['web3_client'].eth.contract(
            address=Web3.to_checksum_address(
                self.protocol_state_contract_address,
            ),
            abi=read_json_file(
                settings.protocol_state.abi,
                self.logger,
            ),
        )

        self._anchor_chain_id = self._anchor_rpc_helper.get_current_node()['web3_client'].eth.chain_id
        self._keccak_hash = lambda x: sha3.keccak_256(x).digest()
        self._domain_separator = make_domain(
            name='PowerloomProtocolContract', version='0.1', chainId=self._anchor_chain_id,
            verifyingContract=self.protocol_state_contract_address,
        )
        self._private_key = settings.signer_private_key
        if self._private_key.startswith('0x'):
            self._private_key = self._private_key[2:]
        self._identity_private_key = PrivateKey.from_hex(settings.signer_private_key)

    async def generate_signature(self, snapshot_cid, epoch_id, project_id, slot_id=None, private_key=None):
        
        current_block = await self._anchor_rpc_helper.eth_get_block()
        current_block_number = int(current_block['number'], 16)
        current_block_hash = current_block['hash']
        deadline = current_block_number + settings.protocol_state.deadline_buffer
        request_slot_id = settings.slot_id if not slot_id else slot_id
        request = EIPRequest(
            slotId=request_slot_id,
            deadline=deadline,
            snapshotCid=snapshot_cid,
            epochId=epoch_id,
            projectId=project_id,
        )

        signable_bytes = request.signable_bytes(self._domain_separator)
        if not private_key:
            signature = self._identity_private_key.sign_recoverable(signable_bytes, hasher=self._keccak_hash)
        else:
            if private_key.startswith('0x'):
                private_key = private_key[2:]
            signer_private_key = PrivateKey.from_hex(private_key)
            signature = signer_private_key.sign_recoverable(signable_bytes, hasher=self._keccak_hash)
        v = signature[64] + 27
        r = big_endian_to_int(signature[0:32])
        s = big_endian_to_int(signature[32:64])

        final_sig = r.to_bytes(32, 'big') + s.to_bytes(32, 'big') + v.to_bytes(1, 'big')
        request_ = {'slotId': request_slot_id, 'deadline': deadline, 'snapshotCid': snapshot_cid, 'epochId': epoch_id, 'projectId': project_id}
        return request_, final_sig, current_block_hash

    async def _init_grpc(self):
        self._grpc_channel = Channel(
            host='snapshotter-lite-local-collector',
            port=settings.local_collector_port,
            ssl=False,
        )
        self._grpc_stub = SubmissionStub(self._grpc_channel)
        self._stream = None
        self._cancel_task = None

    async def _init_protocol_meta(self):
        # TODO: combine these into a single call
        try:
            source_block_time = await self._anchor_rpc_helper.web3_call(
                [
                    self.protocol_state_contract.functions.SOURCE_CHAIN_BLOCK_TIME(
                        Web3.to_checksum_address(settings.data_market),
                    ),
                ],
            )
        except Exception as e:
            self.logger.exception(
                'Exception in querying protocol state for source chain block time: {}',
                e,
            )
        else:
            source_block_time = source_block_time[0]
            self._source_chain_block_time = source_block_time / 10 ** 4
            self.logger.debug('Set source chain block time to {}', self._source_chain_block_time)
        try:
            epoch_size = await self._anchor_rpc_helper.web3_call(
                [self.protocol_state_contract.functions.EPOCH_SIZE(Web3.to_checksum_address(settings.data_market))],
            )
        except Exception as e:
            self.logger.exception(
                'Exception in querying protocol state for epoch size: {}',
                e,
            )
        else:
            self._epoch_size = epoch_size[0]
            self.logger.debug('Set epoch size to {}', self._epoch_size)

    async def init(self):
        """
        Initializes the worker by initializing the HTTPX client, and RPC helper.
        """
        if not self.initialized:
            await self._init_rpc_helper()
            await self._init_protocol_meta()
            await self._init_grpc()
        self.initialized = True
