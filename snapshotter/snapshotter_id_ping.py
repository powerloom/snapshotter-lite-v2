import asyncio
import sys
import os

from web3 import Web3

from snapshotter.settings.config import settings
from snapshotter.utils.file_utils import read_json_file


async def main():
    """
    Checks if snapshotting is allowed for the given instance ID by querying the protocol state contract.
    If snapshotting is allowed, sets the active status key in Redis to True and exits with code 0.
    If snapshotting is not allowed, sets the active status key in Redis to False and exits with code 1.
    """
    # Load protocol state ABI
    protocol_abi = read_json_file(settings.protocol_state.abi)
    print('abi file ', settings.protocol_state.abi)
    print('Contract address: ', settings.protocol_state.address)

    w3 = Web3(Web3.HTTPProvider(settings.powerloom_chain_rpc.full_nodes[0].url))
    
    try:
        block_number = w3.eth.get_block_number()
        print(f"✅ Successfully fetched the latest block number {block_number}. Your ISP is supported!")
    except Exception as e:
        print("❌ Failed to fetch the latest block number. Your ISP/VPS region is not supported ⛔️")
        sys.exit(1)

    protocol_state_contract = w3.eth.contract(address=settings.protocol_state.address, abi=protocol_abi)
    snapshotter_address = w3.eth.account.from_key(settings.signer_private_key).address
    print('Extracted snapshotter address from private key: ', snapshotter_address)

    print('Querying allowed snapshotters...')
    # Query allowed snapshotters
    allowed_snapshotters = protocol_state_contract.functions.allSnapshotters(
        Web3.to_checksum_address(snapshotter_address)
    ).call()

    # Check slot ID mapping
    slot_id_mapping_query = protocol_state_contract.functions.slotSnapshotterMapping(
        settings.slot_id
    ).call()

    if allowed_snapshotters is True or allowed_snapshotters:
        print('✅ Snapshotter identity found in allowed snapshotters...')
    else:
        print('❌ Snapshotter identity check failed on protocol smart contract')
        sys.exit(1)

    try:
        slot_id_snapshotter_addr = Web3.to_checksum_address(slot_id_mapping_query)
        if slot_id_snapshotter_addr == Web3.to_checksum_address(snapshotter_address):
            print('✅ Snapshotter identity found in slot ID mapping...')
        else:
            print('❌ Snapshotter identity not found in slot ID mapping...')
            sys.exit(1)
    except Exception as e:
        print('Error in slot ID mapping query: ', e)
        sys.exit(1)





if __name__ == '__main__':
    asyncio.run(main())
