// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import "src/Metadata.sol";

contract LenderMock {
    address public operator;
    address public manager;

    constructor(address _operator) {
        operator = _operator;
    }

    function setOperator(address _operator) external {
        operator = _operator;
    }

    function setManager(address _manager) external {
        manager = _manager;
    }
}

contract MetadataTest is Test {
    Metadata metadata;
    LenderMock lender;
    address operator = address(0xA11CE);
    address manager = address(0xD00D);
    address stranger = address(0xB0B);
    address priceFeed = address(0xFEED);

    event MetadataUpdated(address indexed lender, Metadata.MetadataValues values);
    event WebsiteUrlUpdated(address indexed lender, string websiteUrl);
    event XUrlUpdated(address indexed lender, string xUrl);
    event DiscordUrlUpdated(address indexed lender, string discordUrl);
    event TelegramUrlUpdated(address indexed lender, string telegramUrl);
    event OtherUrlUpdated(address indexed lender, string otherUrl);
    event CoinLogoUrlUpdated(address indexed lender, string coinLogoUrl);
    event VaultLogoUrlUpdated(address indexed lender, string vaultLogoUrl);
    event ProjectNameUpdated(address indexed lender, string projectName);
    event ProjectLogoUrlUpdated(address indexed lender, string projectLogoUrl);
    event CoinTypeUpdated(address indexed lender, Metadata.CoinType coinType);
    event CoinDenominationUpdated(address indexed lender, string coinDenomination);
    event DescriptionUpdated(address indexed lender, string description);
    event CollateralUsdPriceFeedUpdated(address indexed lender, address collateralUsdPriceFeed);

    function setUp() public {
        metadata = new Metadata();
        lender = new LenderMock(operator);
        lender.setManager(manager);
    }

    function _sampleValues() internal view returns (Metadata.MetadataValues memory) {
        return Metadata.MetadataValues({
            websiteUrl: "https://site.example",
            xUrl: "https://x.com/example",
            discordUrl: "https://discord.gg/example",
            telegramUrl: "https://t.me/example",
            otherUrl: "https://other.example",
            coinLogoUrl: "https://site.example/coin.png",
            vaultLogoUrl: "https://site.example/vault.png",
            projectName: "Example",
            projectLogoUrl: "https://site.example/project.png",
            coinType: Metadata.CoinType.Volatile,
            coinDenomination: "ETH",
            collateralUsdPriceFeed: priceFeed,
            description: "An example market"
        });
    }

    function testSetMetadataRoundTrip() public {
        Metadata.MetadataValues memory v = _sampleValues();

        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit MetadataUpdated(address(lender), v);
        metadata.setMetadata(address(lender), v);

        Metadata.MetadataValues memory r = metadata.getMetadata(address(lender));
        assertEq(r.websiteUrl, v.websiteUrl);
        assertEq(r.xUrl, v.xUrl);
        assertEq(r.discordUrl, v.discordUrl);
        assertEq(r.telegramUrl, v.telegramUrl);
        assertEq(r.otherUrl, v.otherUrl);
        assertEq(r.coinLogoUrl, v.coinLogoUrl);
        assertEq(r.vaultLogoUrl, v.vaultLogoUrl);
        assertEq(r.projectName, v.projectName);
        assertEq(r.projectLogoUrl, v.projectLogoUrl);
        assertEq(uint(r.coinType), uint(v.coinType));
        assertEq(r.coinDenomination, v.coinDenomination);
        assertEq(r.collateralUsdPriceFeed, v.collateralUsdPriceFeed);
        assertEq(r.description, v.description);
    }

    function testSetMetadataRevertsForNonOperator() public {
        Metadata.MetadataValues memory v = _sampleValues();
        vm.prank(stranger);
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setMetadata(address(lender), v);
    }

    function testSetMetadataByManager() public {
        Metadata.MetadataValues memory v = _sampleValues();

        vm.prank(manager);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit MetadataUpdated(address(lender), v);
        metadata.setMetadata(address(lender), v);

        Metadata.MetadataValues memory r = metadata.getMetadata(address(lender));
        assertEq(r.websiteUrl, v.websiteUrl);
        assertEq(r.description, v.description);
    }

    function testIndividualSettersAllowManager() public {
        vm.startPrank(manager);

        metadata.setWebsiteUrl(address(lender), "https://a");
        assertEq(metadata.websiteUrl(address(lender)), "https://a");

        metadata.setXUrl(address(lender), "https://x");
        assertEq(metadata.xUrl(address(lender)), "https://x");

        metadata.setDiscordUrl(address(lender), "https://d");
        assertEq(metadata.discordUrl(address(lender)), "https://d");

        metadata.setTelegramUrl(address(lender), "https://t");
        assertEq(metadata.telegramUrl(address(lender)), "https://t");

        metadata.setOtherUrl(address(lender), "https://o");
        assertEq(metadata.otherUrl(address(lender)), "https://o");

        metadata.setCoinLogoUrl(address(lender), "https://c.png");
        assertEq(metadata.coinLogoUrl(address(lender)), "https://c.png");

        metadata.setVaultLogoUrl(address(lender), "https://v.png");
        assertEq(metadata.vaultLogoUrl(address(lender)), "https://v.png");

        metadata.setProjectName(address(lender), "Acme");
        assertEq(metadata.projectName(address(lender)), "Acme");

        metadata.setProjectLogoUrl(address(lender), "https://p.png");
        assertEq(metadata.projectLogoUrl(address(lender)), "https://p.png");

        metadata.setCoinType(address(lender), Metadata.CoinType.Volatile);
        assertEq(uint(metadata.coinType(address(lender))), uint(Metadata.CoinType.Volatile));

        metadata.setCoinDenomination(address(lender), "USD");
        assertEq(metadata.coinDenomination(address(lender)), "USD");

        metadata.setDescription(address(lender), "desc");
        assertEq(metadata.description(address(lender)), "desc");

        metadata.setCollateralUsdPriceFeed(address(lender), priceFeed);
        assertEq(metadata.collateralUsdPriceFeed(address(lender)), priceFeed);

        vm.stopPrank();
    }

    function testManagerRotationChangesAuthority() public {
        // original manager can set
        vm.prank(manager);
        metadata.setWebsiteUrl(address(lender), "https://one");

        // rotate manager
        lender.setManager(stranger);

        // old manager can no longer set
        vm.prank(manager);
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setWebsiteUrl(address(lender), "https://two");

        // new manager can set
        vm.prank(stranger);
        metadata.setWebsiteUrl(address(lender), "https://three");
        assertEq(metadata.websiteUrl(address(lender)), "https://three");
    }

    function testEmptyGetMetadataReturnsDefaults() public view {
        Metadata.MetadataValues memory r = metadata.getMetadata(address(lender));
        assertEq(r.websiteUrl, "");
        assertEq(uint(r.coinType), uint(Metadata.CoinType.Stablecoin));
        assertEq(r.collateralUsdPriceFeed, address(0));
    }

    function testSetWebsiteUrl() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit WebsiteUrlUpdated(address(lender), "https://a");
        metadata.setWebsiteUrl(address(lender), "https://a");
        assertEq(metadata.websiteUrl(address(lender)), "https://a");
    }

    function testSetWebsiteUrlRevertsForNonOperator() public {
        vm.prank(stranger);
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setWebsiteUrl(address(lender), "https://a");
    }

    function testSetXUrl() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit XUrlUpdated(address(lender), "https://x");
        metadata.setXUrl(address(lender), "https://x");
        assertEq(metadata.xUrl(address(lender)), "https://x");
    }

    function testSetDiscordUrl() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit DiscordUrlUpdated(address(lender), "https://d");
        metadata.setDiscordUrl(address(lender), "https://d");
        assertEq(metadata.discordUrl(address(lender)), "https://d");
    }

    function testSetTelegramUrl() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit TelegramUrlUpdated(address(lender), "https://t");
        metadata.setTelegramUrl(address(lender), "https://t");
        assertEq(metadata.telegramUrl(address(lender)), "https://t");
    }

    function testSetOtherUrl() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit OtherUrlUpdated(address(lender), "https://o");
        metadata.setOtherUrl(address(lender), "https://o");
        assertEq(metadata.otherUrl(address(lender)), "https://o");
    }

    function testSetCoinLogoUrl() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit CoinLogoUrlUpdated(address(lender), "https://c.png");
        metadata.setCoinLogoUrl(address(lender), "https://c.png");
        assertEq(metadata.coinLogoUrl(address(lender)), "https://c.png");
    }

    function testSetVaultLogoUrl() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit VaultLogoUrlUpdated(address(lender), "https://v.png");
        metadata.setVaultLogoUrl(address(lender), "https://v.png");
        assertEq(metadata.vaultLogoUrl(address(lender)), "https://v.png");
    }

    function testSetProjectName() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit ProjectNameUpdated(address(lender), "Acme");
        metadata.setProjectName(address(lender), "Acme");
        assertEq(metadata.projectName(address(lender)), "Acme");
    }

    function testSetProjectLogoUrl() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit ProjectLogoUrlUpdated(address(lender), "https://p.png");
        metadata.setProjectLogoUrl(address(lender), "https://p.png");
        assertEq(metadata.projectLogoUrl(address(lender)), "https://p.png");
    }

    function testSetCoinType() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit CoinTypeUpdated(address(lender), Metadata.CoinType.Volatile);
        metadata.setCoinType(address(lender), Metadata.CoinType.Volatile);
        assertEq(uint(metadata.coinType(address(lender))), uint(Metadata.CoinType.Volatile));
    }

    function testSetCoinDenomination() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit CoinDenominationUpdated(address(lender), "USD");
        metadata.setCoinDenomination(address(lender), "USD");
        assertEq(metadata.coinDenomination(address(lender)), "USD");
    }

    function testSetDescription() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit DescriptionUpdated(address(lender), "desc");
        metadata.setDescription(address(lender), "desc");
        assertEq(metadata.description(address(lender)), "desc");
    }

    function testSetCollateralUsdPriceFeed() public {
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(metadata));
        emit CollateralUsdPriceFeedUpdated(address(lender), priceFeed);
        metadata.setCollateralUsdPriceFeed(address(lender), priceFeed);
        assertEq(metadata.collateralUsdPriceFeed(address(lender)), priceFeed);
    }

    function testIndividualSettersRevertForNonOperator() public {
        vm.startPrank(stranger);

        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setWebsiteUrl(address(lender), "x");
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setXUrl(address(lender), "x");
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setDiscordUrl(address(lender), "x");
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setTelegramUrl(address(lender), "x");
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setOtherUrl(address(lender), "x");
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setCoinLogoUrl(address(lender), "x");
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setVaultLogoUrl(address(lender), "x");
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setProjectName(address(lender), "x");
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setProjectLogoUrl(address(lender), "x");
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setCoinType(address(lender), Metadata.CoinType.Volatile);
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setCoinDenomination(address(lender), "x");
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setDescription(address(lender), "x");
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setCollateralUsdPriceFeed(address(lender), priceFeed);

        vm.stopPrank();
    }

    function testOperatorRotationChangesAuthority() public {
        // original operator can set
        vm.prank(operator);
        metadata.setWebsiteUrl(address(lender), "https://one");

        // rotate operator
        lender.setOperator(stranger);

        // old operator can no longer set
        vm.prank(operator);
        vm.expectRevert(bytes("Only operator or manager can set metadata"));
        metadata.setWebsiteUrl(address(lender), "https://two");

        // new operator can set
        vm.prank(stranger);
        metadata.setWebsiteUrl(address(lender), "https://three");
        assertEq(metadata.websiteUrl(address(lender)), "https://three");
    }

    function testMetadataScopedPerLender() public {
        LenderMock lenderB = new LenderMock(stranger);

        vm.prank(operator);
        metadata.setWebsiteUrl(address(lender), "https://a");

        vm.prank(stranger);
        metadata.setWebsiteUrl(address(lenderB), "https://b");

        assertEq(metadata.websiteUrl(address(lender)), "https://a");
        assertEq(metadata.websiteUrl(address(lenderB)), "https://b");
    }
}
