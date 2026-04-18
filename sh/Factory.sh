#!/usr/bin/env bash

# To load the variables in the .env file
source .env

read -p "Enter network name (e.g. eth-sepolia, eth-mainnet): " NETWORK
read -p "Enter keystore account name: " ACCOUNT

RPC_URL="https://${NETWORK}.g.alchemy.com/v2/${ALCHEMY_API_KEY}"

# To deploy and verify our contract
forge script script/Factory.s.sol:FactoryScript --rpc-url $RPC_URL --broadcast -vvvv --etherscan-api-key $ETHERSCAN_API_KEY --verify --slow --account $ACCOUNT
