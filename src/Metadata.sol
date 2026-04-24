// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

interface ILender {
    function operator() external view returns (address);
    function manager() external view returns (address);
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

    event MetadataUpdated(address indexed lender, MetadataValues values);
    event WebsiteUrlUpdated(address indexed lender, string websiteUrl);
    event XUrlUpdated(address indexed lender, string xUrl);
    event DiscordUrlUpdated(address indexed lender, string discordUrl);
    event TelegramUrlUpdated(address indexed lender, string telegramUrl);
    event OtherUrlUpdated(address indexed lender, string otherUrl);
    event CoinLogoUrlUpdated(address indexed lender, string coinLogoUrl);
    event VaultLogoUrlUpdated(address indexed lender, string vaultLogoUrl);
    event ProjectNameUpdated(address indexed lender, string projectName);
    event ProjectLogoUrlUpdated(address indexed lender, string projectLogoUrl);
    event CoinTypeUpdated(address indexed lender, CoinType coinType);
    event CoinDenominationUpdated(address indexed lender, string coinDenomination);
    event DescriptionUpdated(address indexed lender, string description);
    event CollateralUsdPriceFeedUpdated(address indexed lender, address collateralUsdPriceFeed);

    modifier onlyOperatorOrManager(address _lender) {
        require(
            msg.sender == ILender(_lender).operator() ||
                msg.sender == ILender(_lender).manager(),
            "Only operator or manager can set metadata"
        );
        _;
    }

    function setMetadata(
        address _lender,
        MetadataValues calldata m
    ) external onlyOperatorOrManager(_lender) {
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
        emit MetadataUpdated(_lender, m);
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
    ) external onlyOperatorOrManager(_lender) {
        description[_lender] = _description;
        emit DescriptionUpdated(_lender, _description);
    }

    function setWebsiteUrl(
        address _lender,
        string calldata _websiteUrl
    ) external onlyOperatorOrManager(_lender) {
        websiteUrl[_lender] = _websiteUrl;
        emit WebsiteUrlUpdated(_lender, _websiteUrl);
    }

    function setXUrl(
        address _lender,
        string calldata _xUrl
    ) external onlyOperatorOrManager(_lender) {
        xUrl[_lender] = _xUrl;
        emit XUrlUpdated(_lender, _xUrl);
    }

    function setDiscordUrl(
        address _lender,
        string calldata _discordUrl
    ) external onlyOperatorOrManager(_lender) {
        discordUrl[_lender] = _discordUrl;
        emit DiscordUrlUpdated(_lender, _discordUrl);
    }

    function setTelegramUrl(
        address _lender,
        string calldata _telegramUrl
    ) external onlyOperatorOrManager(_lender) {
        telegramUrl[_lender] = _telegramUrl;
        emit TelegramUrlUpdated(_lender, _telegramUrl);
    }

    function setOtherUrl(
        address _lender,
        string calldata _otherUrl
    ) external onlyOperatorOrManager(_lender) {
        otherUrl[_lender] = _otherUrl;
        emit OtherUrlUpdated(_lender, _otherUrl);
    }

    function setCoinLogoUrl(
        address _lender,
        string calldata _coinLogoUrl
    ) external onlyOperatorOrManager(_lender) {
        coinLogoUrl[_lender] = _coinLogoUrl;
        emit CoinLogoUrlUpdated(_lender, _coinLogoUrl);
    }

    function setVaultLogoUrl(
        address _lender,
        string calldata _vaultLogoUrl
    ) external onlyOperatorOrManager(_lender) {
        vaultLogoUrl[_lender] = _vaultLogoUrl;
        emit VaultLogoUrlUpdated(_lender, _vaultLogoUrl);
    }

    function setProjectName(
        address _lender,
        string calldata _projectName
    ) external onlyOperatorOrManager(_lender) {
        projectName[_lender] = _projectName;
        emit ProjectNameUpdated(_lender, _projectName);
    }

    function setProjectLogoUrl(
        address _lender,
        string calldata _projectLogoUrl
    ) external onlyOperatorOrManager(_lender) {
        projectLogoUrl[_lender] = _projectLogoUrl;
        emit ProjectLogoUrlUpdated(_lender, _projectLogoUrl);
    }

    function setCoinType(
        address _lender,
        CoinType _coinType
    ) external onlyOperatorOrManager(_lender) {
        coinType[_lender] = _coinType;
        emit CoinTypeUpdated(_lender, _coinType);
    }

    function setCoinDenomination(
        address _lender,
        string calldata _coinDenomination
    ) external onlyOperatorOrManager(_lender) {
        coinDenomination[_lender] = _coinDenomination;
        emit CoinDenominationUpdated(_lender, _coinDenomination);
    }

    function setCollateralUsdPriceFeed(
        address _lender,
        address _collateralUsdPriceFeed
    ) external onlyOperatorOrManager(_lender) {
        collateralUsdPriceFeed[_lender] = _collateralUsdPriceFeed;
        emit CollateralUsdPriceFeedUpdated(_lender, _collateralUsdPriceFeed);
    }
}
