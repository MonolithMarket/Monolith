#!/usr/bin/env bash

# To load the variables in the .env file
source .env

# Hardcoded constructor parameters for Lender contract verification
LENDER_ADDRESS="0x44AfC35b52dbeBF43e1940D4f12C372446D52D5A"
COLLATERAL_ADDRESS="0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0"
FEED_ADDRESS="0x894B896cDc772656Cbb1eE28e6Bd4a704caA7b61"
COIN_ADDRESS="0x7e625503F9A5cE5A878BfA2adb0F5C1c6cC31018"
VAULT_ADDRESS="0x44981da1699BF82cF866de369b4F6bE7c06ed731"
INTEREST_MODEL_ADDRESS="0x98de3Faa00c63a4547d06Acb0818465B485c083c"
FACTORY_ADDRESS="0x9d556a572145cff26ef00ba00f004791a45419b1"
OPERATOR_ADDRESS="0xD9a3f7E1AEC3ED77d5Eb7f738Eb27a936bf7F790"
COLLATERAL_FACTOR="8500"
MIN_DEBT="10000000000000000000"
TIME_UNTIL_IMMUTABILITY="31536000"

# Verify the Lender contract
forge verify-contract \
    $LENDER_ADDRESS \
    src/Lender.sol:Lender \
    --rpc-url $RPC_URL \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,address,address,uint256,uint256,uint256)" \
        $COLLATERAL_ADDRESS \
        $FEED_ADDRESS \
        $COIN_ADDRESS \
        $VAULT_ADDRESS \
        $INTEREST_MODEL_ADDRESS \
        $FACTORY_ADDRESS \
        $OPERATOR_ADDRESS \
        $COLLATERAL_FACTOR \
        $MIN_DEBT \
        $TIME_UNTIL_IMMUTABILITY) \
    --watch
