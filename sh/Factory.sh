#!/usr/bin/env bash

# To load the variables in the .env file
source .env

read -p "Enter keystore account name: " ACCOUNT

# To deploy and verify our contract
forge script script/Factory.s.sol:FactoryScript --rpc-url $RPC_URL --broadcast -vvvv --etherscan-api-key $ETHERSCAN_API_KEY --verify --slow --account $ACCOUNT
