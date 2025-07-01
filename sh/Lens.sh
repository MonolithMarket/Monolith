#!/usr/bin/env bash

# To load the variables in the .env file
source .env

# To deploy and verify our contract
forge script script/Lens.s.sol:LensScript --rpc-url $RPC_URL --broadcast -vvvv --etherscan-api-key $ETHERSCAN_API_KEY --verify --slow --private-key $PRIVATE_KEY