// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.13;

interface ILender {
    function operator() external view returns (address);
}
contract Metadata {
    enum CoinType {
        Stablecoin,
        Volatile
    }

    mapping(address => string) public websiteUrl;
    mapping(address => string) public xUrl;
    mapping(address => string) public discordUrl;
    mapping(address => string) public telegramUrl;
    mapping(address => string) public otherUrl;
    mapping(address => string) public coinLogoUrl;
    mapping(address => string) public vaultLogoUrl;
    mapping(address => string) public projectName;
    mapping(address => string) public projectLogoUrl;
    mapping(address => CoinType) public coinType;
    mapping(address => string) public coinDenomination;
    mapping(address => string) public description;
    // price feed for the collateral asset in case the market price feed is not denominated in USD
    mapping(address => address) public collateralUsdPriceFeed;

    modifier onlyOperator(address _lender) {
        require(
            msg.sender == ILender(_lender).operator(),
            "Only operator can set metadata"
        );
        _;
    }

    struct MetadataValues {
        string websiteUrl;
        string xUrl;
        string discordUrl;
        string telegramUrl;
        string otherUrl;
        string coinLogoUrl;
        string vaultLogoUrl;
        string projectName;
        string projectLogoUrl;
        CoinType coinType;
        string coinDenomination;
        address collateralUsdPriceFeed;
        string description;
    }

    function setMetadata(
        address _lender,
        MetadataValues calldata m
    ) external onlyOperator(_lender) {
        websiteUrl[_lender] = m.websiteUrl;
        xUrl[_lender] = m.xUrl;
        discordUrl[_lender] = m.discordUrl;
        telegramUrl[_lender] = m.telegramUrl;
        otherUrl[_lender] = m.otherUrl;
        coinLogoUrl[_lender] = m.coinLogoUrl;
        vaultLogoUrl[_lender] = m.vaultLogoUrl;
        projectName[_lender] = m.projectName;
        projectLogoUrl[_lender] = m.projectLogoUrl;
        coinType[_lender] = m.coinType;
        coinDenomination[_lender] = m.coinDenomination;
        collateralUsdPriceFeed[_lender] = m.collateralUsdPriceFeed;
        description[_lender] = m.description;
    }

    function getMetadata(
        address _lender
    ) external view returns (MetadataValues memory) {
        return
            MetadataValues({
                websiteUrl: websiteUrl[_lender],
                xUrl: xUrl[_lender],
                discordUrl: discordUrl[_lender],
                telegramUrl: telegramUrl[_lender],
                otherUrl: otherUrl[_lender],
                coinLogoUrl: coinLogoUrl[_lender],
                vaultLogoUrl: vaultLogoUrl[_lender],
                projectName: projectName[_lender],
                projectLogoUrl: projectLogoUrl[_lender],
                coinType: coinType[_lender],
                coinDenomination: coinDenomination[_lender],
                collateralUsdPriceFeed: collateralUsdPriceFeed[_lender],
                description: description[_lender]
            });
    }

    function setDescription(
        address _lender,
        string calldata _description
    ) external onlyOperator(_lender) {
        description[_lender] = _description;
    }

    function setWebsiteUrl(
        address _lender,
        string calldata _websiteUrl
    ) external onlyOperator(_lender) {
        websiteUrl[_lender] = _websiteUrl;
    }

    function setXUrl(
        address _lender,
        string calldata _xUrl
    ) external onlyOperator(_lender) {
        xUrl[_lender] = _xUrl;
    }

    function setDiscordUrl(
        address _lender,
        string calldata _discordUrl
    ) external onlyOperator(_lender) {
        discordUrl[_lender] = _discordUrl;
    }

    function setTelegramUrl(
        address _lender,
        string calldata _telegramUrl
    ) external onlyOperator(_lender) {
        telegramUrl[_lender] = _telegramUrl;
    }

    function setOtherUrl(
        address _lender,
        string calldata _otherUrl
    ) external onlyOperator(_lender) {
        otherUrl[_lender] = _otherUrl;
    }

    function setCoinLogoUrl(
        address _lender,
        string calldata _coinLogoUrl
    ) external onlyOperator(_lender) {
        coinLogoUrl[_lender] = _coinLogoUrl;
    }

    function setVaultLogoUrl(
        address _lender,
        string calldata _vaultLogoUrl
    ) external onlyOperator(_lender) {
        vaultLogoUrl[_lender] = _vaultLogoUrl;
    }

    function setProjectName(
        address _lender,
        string calldata _projectName
    ) external onlyOperator(_lender) {
        projectName[_lender] = _projectName;
    }

    function setProjectLogoUrl(
        address _lender,
        string calldata _projectLogoUrl
    ) external onlyOperator(_lender) {
        projectLogoUrl[_lender] = _projectLogoUrl;
    }

    function setCoinType(
        address _lender,
        CoinType _coinType
    ) external onlyOperator(_lender) {
        coinType[_lender] = _coinType;
    }

    function setCoinDenomination(
        address _lender,
        string calldata _coinDenomination
    ) external onlyOperator(_lender) {
        coinDenomination[_lender] = _coinDenomination;
    }

    function setCollateralUsdPriceFeed(
        address _lender,
        address _collateralUsdPriceFeed
    ) external onlyOperator(_lender) {
        collateralUsdPriceFeed[_lender] = _collateralUsdPriceFeed;
    }
}