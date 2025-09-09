from snapshotter.utils.callback_helpers import GenericPreloader
from snapshotter.utils.default_logger import logger
from snapshotter.utils.models.data_models import PreloaderResult
from snapshotter.utils.models.message_models import EpochBase
from rpc_helper.rpc import RpcHelper
from snapshotter.utils.snapshot_utils import get_block_details_in_block_range


class BlockDetailsPreloader(GenericPreloader):
    """
    A preloader class for fetching block details for a range of blocks.
    
    This class extends GenericPreloader and implements methods to fetch
    and store block details for a given epoch range.
    """

    def __init__(self) -> None:
        """
        Initialize the BlockDetailsPreloader with a logger.
        """
        self._logger = logger.bind(module='BlockDetailsPreloader')

    async def compute(
            self,
            epoch: EpochBase,
            rpc_helper: RpcHelper,
    ) -> PreloaderResult:
        """
        Compute and store block details for the given epoch range.

        Args:
            epoch (EpochBase): The epoch containing the block range.
            rpc_helper (RpcHelper): Helper for making RPC calls.

        Returns:
            PreloaderResult: Contains the block details for the epoch range.
        """
        try:
            block_details = await get_block_details_in_block_range(
                from_block=int(epoch.begin),
                to_block=int(epoch.end),
                rpc_helper=rpc_helper,
            )
            return PreloaderResult(
                keyword='block_details',
                result=block_details,
            )
        except Exception as e:
            self._logger.error(f'Error in Block Details preloader: {e}')
            raise e
        
    async def cleanup(self):
        """
        Perform any necessary cleanup operations.

        This method is currently a placeholder and does not perform any actions.
        It can be implemented in the future if cleanup operations are needed.
        """
        pass
