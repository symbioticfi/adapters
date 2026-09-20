// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ExecutingRecipe} from "script/recipes/ExecutingRecipe.sol";
import {RecipeExecutor} from "src/contracts/merkle-adapter/automations/RecipeExecutor.sol";
import {IRecipeExecutor} from "src/interfaces/merkle-adapter/automations/IRecipeExecutor.sol";
import {AdapterFactory} from "src/contracts/AdapterFactory.sol";
import {CapabilitiesRegistry} from "src/contracts/merkle-adapter/CapabilitiesRegistry.sol";
import {LiquidLaneConnector} from "src/contracts/merkle-adapter/connectors/LiquidLaneConnector.sol";
import {MerkleAdapter} from "src/contracts/MerkleAdapter.sol";
import {OracleRegistry} from "src/contracts/merkle-adapter/oracle/OracleRegistry.sol";
import {RootRegistry} from "src/contracts/merkle-adapter/RootRegistry.sol";

import {IAsyncRedeemVault} from "src/interfaces/ll-adapter/IAsyncRedeemVault.sol";
import {IDigiFTSubRedManagement} from "src/interfaces/ll-adapter/digift/IDigiFTSubRedManagement.sol";
import {IERC7575Share} from "src/interfaces/ll-adapter/IERC7575Share.sol";
import {IEtherFiLiquidityPool} from "src/interfaces/ll-adapter/etherfi/IEtherFiLiquidityPool.sol";
import {IFigureYieldVault} from "src/interfaces/ll-adapter/figure/IFigureYieldVault.sol";
import {IInfiniFiGateway} from "src/interfaces/ll-adapter/infinifi/IInfiniFiGateway.sol";
import {IInfiniFiUnwindingModule} from "src/interfaces/ll-adapter/infinifi/IInfiniFiUnwindingModule.sol";
import {ILidoWithdrawalQueue} from "src/interfaces/ll-adapter/lido/ILidoWithdrawalQueue.sol";
import {ILiquidLaneConnector} from "src/interfaces/merkle-adapter/connectors/ILiquidLaneConnector.sol";
import {IMakinaRedeemer} from "src/interfaces/ll-adapter/makina/IMakinaRedeemer.sol";
import {IMerkleAdapter} from "src/interfaces/IMerkleAdapter.sol";
import {IMidasDataFeed} from "src/interfaces/ll-adapter/midas/IMidasOracle.sol";
import {IMidasRedemptionVault} from "src/interfaces/ll-adapter/midas/IMidasRedemptionVault.sol";
import {INoonWithdrawalHandler} from "src/interfaces/ll-adapter/noon/INoonWithdrawalHandler.sol";
import {IOpenEdenExpress} from "src/interfaces/ll-adapter/openeden/IOpenEdenExpress.sol";
import {IParetoCDO} from "src/interfaces/ll-adapter/pareto/IParetoCDO.sol";
import {IParetoCreditVault} from "src/interfaces/ll-adapter/pareto/IParetoCreditVault.sol";
import {IParetoWithdrawalQueue} from "src/interfaces/ll-adapter/pareto/IParetoWithdrawalQueue.sol";
import {ISThreeJaneSUSD3} from "src/interfaces/ll-adapter/sthreejane/ISThreeJaneSUSD3.sol";
import {ISaid} from "src/interfaces/ll-adapter/gaib/ISaid.sol";
import {ISecuritizeOffRamp} from "src/interfaces/ll-adapter/securitize/ISecuritizeOffRamp.sol";
import {ISpikoRedemption} from "src/interfaces/ll-adapter/spiko/ISpikoRedemption.sol";
import {ISthUSD} from "src/interfaces/ll-adapter/theo/ISthUSD.sol";
import {ISuperstateToken} from "src/interfaces/ll-adapter/superstate/ISuperstateToken.sol";
import {IWeETH} from "src/interfaces/ll-adapter/etherfi/IWeETH.sol";

import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IAccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {MigratablesFactory} from "@symbioticfi/core/src/contracts/common/MigratablesFactory.sol";

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {
    IDSServiceConsumer,
    IDSRegistryService,
    IDSecuritizeToken,
    IDSComplianceConfigurationService,
    IOwnable
} from "test/adapters/ll-adapter/tokens_to_redeem/TokensToRedeemMainnet.t.sol";
import {
    MerkleAdapterVaultRegistry,
    MerkleAdapterVaultMock,
    MerkleAdapterDelegatorMock,
    MerkleAdapterOracleMock
} from "test/adapters/MerkleAdapter.t.sol";

/// @dev Real mainnet token/issuer calls through RecipeExecutor, MerkleAdapter and LiquidLaneConnector.
/// Funding balances are seeded, and vault/NAV/connector pricing are test fixtures. Issuer calls are
/// never mocked. Tests that enroll fresh contracts impersonate the real issuer administrator on
/// the fork; these tests establish calldata compatibility, not permissionless production access.
contract RecipeRedemptionsMainnetTest is Test {
    bytes internal _recipe;

    using ExecutingRecipe for ExecutingRecipe.Builder;
    uint256 internal _approve;
    uint256 internal _swap;
    uint256 internal _clear;
    uint256 internal _redeem;
    uint256 internal _recipeLength;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant SUSN = 0xE24a3DC889621612422A64E6388927901608B91D;
    address internal constant SUSD3 = 0xf689555121e529Ff0463e191F9Bd9d1E496164a7;
    address internal constant USD3 = 0x056B269Eb1f75477a8666ae8C7fE01b64dD55eCc;
    address internal constant PARETO_TOKEN = 0xC26A6Fa2C37b38E549a4a1807543801Db684f99C;
    address internal constant PARETO_QUEUE = 0x5cC24f44cCAa80DD2c079156753fc1e908F495DC;
    address internal constant PARETO_CDO = 0x433D5B175148dA32Ffe1e1A37a939E1b7e79be4d;

    address internal adapter;
    address internal executor;
    address internal lane;
    address internal roots;
    address internal registry;
    address internal recipient;
    uint256 internal fundingAmount;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true, "ETH_RPC_URL required for real issuer verification");
        uint256 forkBlock = vm.envOr("MAINNET_FORK_BLOCK", uint256(26_005_394));
        vm.createSelectFork(rpc, forkBlock);

        address vault = address(new MerkleAdapterVaultMock(USDC));
        address delegator = address(new MerkleAdapterDelegatorMock(vault));
        MerkleAdapterVaultMock(vault).setDelegator(delegator);
        address vaults = address(new MerkleAdapterVaultRegistry());
        MerkleAdapterVaultRegistry(vaults).add(vault);
        address adapters = address(new AdapterFactory(address(this)));
        address oracles = address(new MigratablesFactory(address(this)));
        MigratablesFactory(oracles).whitelist(address(new MerkleAdapterOracleMock(oracles)));
        roots = address(new RootRegistry(address(this)));
        AdapterFactory(adapters)
            .whitelist(
                address(
                    new MerkleAdapter(
                        vaults, adapters, oracles, roots, address(new CapabilitiesRegistry(address(this)))
                    )
                )
            );
        adapter = AdapterFactory(adapters)
            .create(1, address(this), abi.encode(vault, abi.encode(IMerkleAdapter.InitParams(address(this)))));
        registry = address(new OracleRegistry(address(this)));
        address lanes = address(new MigratablesFactory(address(this)));
        MigratablesFactory(lanes).whitelist(address(new LiquidLaneConnector(lanes, registry)));
        lane = MigratablesFactory(lanes).create(1, address(this), abi.encode(adapter, USDC, new address[](0)));
        executor = address(new RecipeExecutor(address(this), adapter));
        RecipeExecutor(executor).setCaller(address(this));
        recipient = makeAddr("post-action-recipient");
    }

    function test_Mainnet_ACRDX() public {
        _centrifuge(0x9477724Bb54AD5417de8Baff29e59DF3fB4DA74f);
    }

    function test_Mainnet_CarryTradeUSDTRYLeverage() public {
        _midas(
            0x2bf11d2E04Bc40daa95c24B8b90EC4F5c57Dd326,
            0xD980df2A697bfd38279BE1Ee2bc13495c101d5C9,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_HYB() public {
        _centrifuge(0x4827C7ecce4f07ADfe44A97165f06A199e7d2505);
    }

    function test_Mainnet_JAAA() public {
        _centrifuge(0x5a0F93D040De44e78F251b03c43be9CF317Dcf64);
    }

    function test_Mainnet_JTRSY() public {
        _centrifuge(0x8c213ee79581Ff4984583C6a801e5263418C4b86);
    }

    function test_Mainnet_StockMarketTRBasisTrade() public {
        _midas(
            0x827Ce7E8e35861D9Ac7fE002755767b695A5594a,
            0x85A7A5FFf71EaEF79e76730F2E717A04aADea27B,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_deCRDX() public {
        _centrifuge(0x9E2679eABFF131b8b1b48fF7566140794E0eEdc4);
    }

    function test_Mainnet_deJAAA() public {
        _centrifuge(0xAAA0008C8CF3A7Dca931adaF04336A5D808C82Cc);
    }

    function test_Mainnet_deJTRSY() public {
        _centrifuge(0xA6233014B9b7aaa74f38fa1977ffC7A89642dC72);
    }

    function test_Mainnet_mAPOLLO() public {
        _midas(
            0x7CF9DEC92ca9FD46f8d86e7798B72624Bc116C05,
            0x5aeA6D35ED7B3B7aE78694B7da2Ee880756Af5C0,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mBASIS() public {
        _midas(
            0x2a8c22E3b10036f3AEF5875d04f8441d4188b656,
            0x19AB19e61A930bc5C7B75Bf06cDd954218Ca9F0b,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mBTC() public {
        _midas(
            0x007115416AB6c266329a03B09a8aa39aC2eF7d9d,
            0x30d9D1e76869516AEa980390494AaEd45C3EfC1a,
            0x18084fbA666a33d37592fA2633fD49a74DD93a88
        );
    }

    function test_Mainnet_mEDGE() public {
        _midas(
            0xbB51E2a15A9158EBE2b0Ceb8678511e063AB7a55,
            0x9B2C5E30E3B1F6369FC746A1C1E47277396aF15D,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mEVUSD() public {
        _midas(
            0x548857309BEfb6Fb6F20a9C5A56c9023D892785B,
            0x9C3743582e8b2d7cCb5e08caF3c9C33780ac446f,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mFARM() public {
        _midas(
            0xA19f6e0dF08a7917F2F8A33Db66D0AF31fF5ECA6,
            0xf4F042D90f0C0d3ABA4A30Caa6Ac124B14A7e600,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mFONE() public {
        _midas(
            0x238a700eD6165261Cf8b2e544ba797BC11e466Ba,
            0x44b0440e35c596e858cEA433D0d82F5a985fD19C,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mGLOBAL() public {
        _midas(
            0x7433806912Eae67919e66aea853d46Fa0aef98A8,
            0x1e0fd66753198c7b8bA64edEe8d41D8628Bf20D7,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mHYPER() public {
        _midas(
            0x9b5528528656DBC094765E2abB79F293c21191B9,
            0x6Be2f55816efd0d91f52720f096006d63c366e98,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mHyperBTC() public {
        _midas(
            0xC8495EAFf71D3A563b906295fCF2f685b1783085,
            0x16d4f955B0aA1b1570Fe3e9bB2f8c19C407cdb67,
            0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf
        );
    }

    function test_Mainnet_mHyperETH() public {
        _midas(
            0x5a42864b14C0C8241EF5ab62Dae975b163a2E0C1,
            0x15f724b35A75F0c28F352b952eA9D1b24e348c57,
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
        );
    }

    function test_Mainnet_mM1USD() public {
        _midas(
            0xCc5C22C7A6BCC25e66726AeF011dDE74289ED203,
            0x70Ba3211f2584Bf1C8a2aCdF0a00dba559CE1Ffa,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mMEV() public {
        _midas(
            0x030b69280892c888670EDCDCD8B69Fd8026A0BF3,
            0xac14a14f578C143625Fc8F54218911e8F634184D,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mROX() public {
        _midas(
            0x67E1F506B148d0Fc95a4E3fFb49068ceB6855c05,
            0xc33dAdA688f224c514682Ec6Ba940888d43C4b29,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mRe7BTC() public {
        _midas(
            0x9FB442d6B612a6dcD2acC67bb53771eF1D9F661A,
            0x4Fd4DD7171D14e5bD93025ec35374d2b9b4321b0,
            0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599
        );
    }

    function test_Mainnet_mRe7YIELD() public {
        _midas(
            0x87C9053C819bB28e0D73d33059E1b3DA80AFb0cf,
            0x5356B8E06589DE894D86B24F4079c629E8565234,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mSL() public {
        _midas(
            0x76CC16608aA7Cd32631bb151801bb095313F7bbd,
            0x8Bee3870Ad8293dcE79E6f4cb049F7531Bd57c22,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mTBILL() public {
        _midas(
            0xDD629E5241CbC5919847783e6C96B2De4754e438,
            0xF6e51d24F4793Ac5e71e0502213a9BBE3A6d4517,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_mevBTC() public {
        _midas(
            0xb64C014307622eB15046C66fF71D04258F5963DC,
            0x2d7d5b1706653796602617350571B3F8999B950c,
            0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599
        );
    }

    function test_Mainnet_msyrupUSD() public {
        _midas(
            0x20226607b4fa64228ABf3072Ce561d6257683464,
            0x9f7dd5462C183B6577858e16a13A4d864CE2f972,
            0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
        );
    }

    function test_Mainnet_msyrupUSDp() public {
        _midas(
            0x2fE058CcF29f123f9dd2aEC0418AA66a877d8E50,
            0x71EFa7AF1686C5c04AA34a120a91cb4262679C44,
            0xdAC17F958D2ee523a2206206994597C13D831ec7
        );
    }

    function test_Mainnet_PRIME() public {
        _figure(0x19ebb35279A16207Ec4ba82799CC64715065F7F6);
    }

    function test_Mainnet_AUTO() public {
        _figure(0x997E2Efbce91D170B00EA402e35a66C887EE1da9);
    }

    function test_Mainnet_sAID() public {
        address token = 0xB3B3c527BA57cd61648e2EC2F5e006A0B390A9F8;
        _configure(token, 1 ether);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(token, abi.encodeCall(ISaid.unstake, (1 ether)));
        _execute(token, 1 ether, posts);
        (, uint256 pending) = ISaid(token).getUnstakeRequest(adapter);
        assertGt(pending, 0);
    }

    function test_Mainnet_sthUSD() public {
        address token = 0xA808Bc9775cb41c52C7842f8b50427fE7A770326;
        _configure(token, 1 ether);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(token, abi.encodeCall(ISthUSD.initiateRedeem, (1 ether, adapter)));
        _execute(token, 1 ether, posts);
        (uint256 assets, uint256 shares, uint256 claimableTimestamp) = ISthUSD(token).currentRedeemRequest(adapter);
        assertEq(shares, 1 ether);
        assertGt(assets, 0);
        assertGt(claimableTimestamp, block.timestamp);
    }

    function test_Mainnet_sUSN() public {
        address handler = 0x0DaBc0D9B270c9B0C4C77AaCeAa712b56D0F9178;
        _configure(SUSN, 1 ether);
        uint256 id = INoonWithdrawalHandler(handler).getUserNextRequestId(adapter);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(SUSN, abi.encodeCall(IERC4626.redeem, (1 ether, handler, adapter)));
        _execute(SUSN, 1 ether, posts);
        INoonWithdrawalHandler.WithdrawalRequest memory request =
            INoonWithdrawalHandler(handler).getWithdrawalRequest(adapter, id);
        assertGt(request.amount, 0);
        assertFalse(request.claimed);
    }

    function test_Mainnet_USD3() public {
        uint256 amount = 10 ** IERC20Metadata(USD3).decimals();
        _configure(USD3, amount);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(USD3, abi.encodeCall(IERC4626.redeem, (amount, adapter, adapter)));
        _execute(USD3, amount, posts);
        assertGt(IERC20(USDC).balanceOf(adapter), 0, "native USDC proceeds missing");
    }

    function test_Mainnet_sUSD3CooldownFailsAtomically() public {
        uint256 amount = 10 ** IERC20Metadata(SUSD3).decimals();
        _configure(SUSD3, amount);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(SUSD3, abi.encodeCall(ISThreeJaneSUSD3.startCooldown, (amount)));
        IMerkleAdapter.Action[] memory actions = _prepare(SUSD3, amount, posts);
        vm.expectRevert(IRecipeExecutor.CheckFailed.selector);
        _runRecipe(actions, posts);
        assertEq(IERC20(SUSD3).balanceOf(lane), amount);
        assertEq(IERC20(SUSD3).balanceOf(adapter), 7);
        assertEq(IERC20(USDC).balanceOf(recipient), 0);
        (,, uint256 cooled) = ISThreeJaneSUSD3(SUSD3).getCooldownStatus(adapter);
        assertEq(cooled, 0, "failed batch must not leave a cooldown");
    }

    function test_Mainnet_sUSD3RedeemAfterActualCooldown() public {
        uint256 amount = 10 ** IERC20Metadata(SUSD3).decimals();
        _configure(SUSD3, amount);
        _seed(SUSD3, adapter, amount + 7);
        vm.prank(adapter);
        ISThreeJaneSUSD3(SUSD3).startCooldown(amount);
        (uint256 end, uint256 windowEnd, uint256 cooledBefore) = ISThreeJaneSUSD3(SUSD3).getCooldownStatus(adapter);
        vm.warp(end + 1);
        assertLe(block.timestamp, windowEnd);
        // The issuer rounds assets and shares down separately; use the actual executable share cap.
        uint256 redeemable = IERC4626(SUSD3).maxRedeem(adapter);
        assertGt(redeemable, 0, "no executable cooled shares");
        _seed(SUSD3, lane, redeemable);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(SUSD3, abi.encodeCall(IERC4626.redeem, (redeemable, adapter, adapter)));
        IMerkleAdapter.Action[] memory actions = _prepare(SUSD3, redeemable, posts);
        _runRecipe(actions, posts);
        assertEq(IERC20(SUSD3).balanceOf(adapter), amount + 7);
        assertEq(IERC20(SUSD3).balanceOf(lane), 0);
        assertEq(IERC20(USDC).balanceOf(recipient), fundingAmount);
        assertGt(IERC20(USD3).balanceOf(adapter), 0);
        (,, uint256 cooledAfter) = ISThreeJaneSUSD3(SUSD3).getCooldownStatus(adapter);
        assertEq(cooledAfter, cooledBefore - redeemable);
    }

    function test_Mainnet_liUSD4w() public {
        _infinifi(0x66bCF6151D5558AfB47c38B20663589843156078, 4);
    }

    function test_Mainnet_liUSD13w() public {
        _infinifi(0xbd3f9814eB946E617f1d774A6762cDbec0bf087A, 13);
    }

    function test_Mainnet_wstETH() public {
        address token = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
        address queue = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;
        _configure(token, 1 ether);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](2);
        posts[0] = _action(token, abi.encodeCall(IERC20.approve, (queue, 1 ether)));
        posts[1] = _action(queue, abi.encodeCall(ILidoWithdrawalQueue.requestWithdrawalsWstETH, (amounts, adapter)));
        _execute(token, 1 ether, posts);
        uint256[] memory ids = ILidoPostQueue(queue).getWithdrawalRequests(adapter);
        assertEq(ids.length, 1);
        ILidoWithdrawalQueue.WithdrawalRequestStatus[] memory statuses =
            ILidoWithdrawalQueue(queue).getWithdrawalStatus(ids);
        assertEq(statuses[0].owner, adapter);
        assertGt(statuses[0].amountOfStETH, 0);
        assertFalse(statuses[0].isClaimed);
    }

    function test_Mainnet_weETH() public {
        address token = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
        address eeth = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
        address pool = 0x308861A430be4cce5502d0A12724771Fc6DaF216;
        address nft = 0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c;
        _configure(token, 1 ether);
        _installNFTReceiver();
        uint256 output = IWeETH(token).getEETHByWeETH(1 ether);
        uint256 beforeNfts = IERC20(nft).balanceOf(adapter);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](3);
        posts[0] = _action(token, abi.encodeCall(IWeETH.unwrap, (1 ether)));
        posts[1] = _action(eeth, abi.encodeCall(IERC20.approve, (pool, output)));
        posts[2] = _action(pool, abi.encodeCall(IEtherFiLiquidityPool.requestWithdraw, (adapter, output)));
        _execute(token, 1 ether, posts);
        assertEq(IERC20(nft).balanceOf(adapter), beforeNfts + 1, "issuer withdrawal NFT missing");
    }

    function test_Mainnet_HYBOND() public {
        address token = 0x1204371AC0e5176f4B8c5B2F16C2Bec551b6FC1a;
        address express = 0xD84C2571E05a59108Ead1c600D16133f0710E569;
        address kyc = IOpenEdenPostExpress(express).kycManager();
        bytes32 role = IOpenEdenPostKyc(kyc).WHITELIST_ROLE();
        address operator = IAccessControlEnumerable(kyc).getRoleMember(role, 0);
        vm.startPrank(operator);
        IOpenEdenPostKyc(kyc).grantKyc(adapter);
        IOpenEdenPostKyc(kyc).grantKyc(lane);
        vm.stopPrank();
        uint256 amount = IOpenEdenPostExpress(express).redeemMinimum();
        _configure(token, amount);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](2);
        posts[0] = _action(token, abi.encodeCall(IERC20.approve, (express, amount)));
        posts[1] = _action(express, abi.encodeCall(IOpenEdenExpress.requestRedeem, (adapter, amount)));
        _execute(token, amount, posts);
        assertEq(IOpenEdenExpress(express).pendingRedeemInfo(adapter), amount);
    }

    function test_Mainnet_ParetoApproveAndTwoRedemptions() public {
        // Fork-only protocol governance: no simulated Keyring or epoch replies.
        vm.prank(IOwnable(PARETO_CDO).owner());
        IParetoPostAdmin(PARETO_CDO).setKeyringParams(address(0), 0);
        assertTrue(IParetoCDO(PARETO_CDO).isWalletAllowed(adapter));
        _configure(PARETO_TOKEN, 1 ether);
        uint256 epoch = IParetoCreditVault(IParetoWithdrawalQueue(PARETO_QUEUE).strategy()).epochNumber() + 1;
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](3);
        posts[0] = _action(PARETO_TOKEN, abi.encodeCall(IERC20.approve, (PARETO_QUEUE, 1 ether)));
        posts[1] = _action(PARETO_QUEUE, abi.encodeCall(IParetoWithdrawalQueue.requestWithdraw, (0.4 ether)));
        posts[2] = _action(PARETO_QUEUE, abi.encodeCall(IParetoWithdrawalQueue.requestWithdraw, (0.6 ether)));
        _execute(PARETO_TOKEN, 1 ether, posts);
        assertEq(IParetoWithdrawalQueue(PARETO_QUEUE).userWithdrawalsEpochs(adapter, epoch), 1 ether);
        assertEq(IERC20(PARETO_TOKEN).allowance(adapter, PARETO_QUEUE), 0);
    }

    function test_Mainnet_ACRED() public {
        _securitizeNotice(0x17418038ecF73BA4026c4f428547BF099706F27B);
    }

    function test_Mainnet_STAC() public {
        _securitizeNotice(0x51C2d74017390CbBd30550179A16A1c28F7210fc);
    }

    function test_Mainnet_VBILL() public {
        address token = 0x2255718832bC9fD3bE1CaF75084F4803DA14FF01;
        address offRamp = 0x1eD617529d80AE87E6611f11D8de8532ECED42bC;
        address rlusd = 0x8292Bb45bf1Ee4d140127049757C2E0fF06317eD;
        uint256 amount = 10 ** IERC20Metadata(token).decimals();
        _permissionSecuritize(token, amount, true);
        _configure(token, amount);
        uint256 expected = ISecuritizeOffRamp(offRamp).calculateLiquidityTokenAmount(amount);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](2);
        posts[0] = _action(token, abi.encodeCall(IERC20.approve, (offRamp, amount)));
        posts[1] = _action(offRamp, abi.encodeCall(ISecuritizeOffRamp.redeem, (amount, expected)));
        _execute(token, amount, posts);
        assertEq(IERC20(rlusd).balanceOf(adapter), expected);
    }

    function test_Mainnet_DUSD() public {
        address token = 0x1e33E98aF620F1D563fcD3cfd3C75acE841204ef;
        address redeemer = 0x1303c26cFE06bac5bfEE29907f37919643DEF75c;
        _configure(token, 1 ether);
        _installNFTReceiver();
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](2);
        posts[0] = _action(token, abi.encodeCall(IERC20.approve, (redeemer, 1 ether)));
        posts[1] = _action(redeemer, abi.encodeCall(IMakinaRedeemer.requestRedeem, (1 ether, adapter, 0)));
        _execute(token, 1 ether, posts);
        assertGt(IERC20(redeemer).balanceOf(adapter), 0, "Makina receipt NFT missing");
    }

    function test_Mainnet_bEQTYRequiresIssuerSignedEnrollment() public {
        address token = 0xEaFD6D38f41f882BCFd5fEaABccCc714B983b701;
        address manager = 0x3797C46db697c24a983222c335F17Ba28e8c5b69;
        uint256 amount = 10 ** IERC20Metadata(token).decimals();
        _configure(token, amount);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](2);
        posts[0] = _action(token, abi.encodeCall(IERC20.approve, (manager, amount)));
        posts[1] =
            _action(manager, abi.encodeCall(IDigiFTSubRedManagement.redeem, (token, USDC, amount, block.timestamp)));
        IMerkleAdapter.Action[] memory actions = _prepare(token, amount, posts);
        // DigiFT's addWhiteContract requires issuer multisignatures. Pranking an administrator
        // cannot create them; retain the real transfer restriction instead of mocking enrollment.
        vm.expectRevert(bytes("Forbid transfer"));
        _runRecipe(actions, posts);
        assertEq(IERC20(token).balanceOf(lane), amount);
        assertEq(IERC20(token).balanceOf(adapter), 7);
        assertEq(IERC20(USDC).balanceOf(recipient), 0);
    }

    function test_Mainnet_USCC() public {
        address token = 0x14d60E7FDC0D71d8611742720E4C50E7a974020c;
        address allowList = 0x02f1fA8B196d21c7b733EB2700B825611d8A38E5;
        vm.startPrank(IOwnable(allowList).owner());
        ISuperstatePostAllowList(allowList).setProtocolAddressPermission(lane, "USCC", true);
        ISuperstatePostAllowList(allowList).setProtocolAddressPermission(adapter, "USCC", true);
        vm.stopPrank();
        uint256 amount = 10 ** IERC20Metadata(token).decimals();
        _configure(token, amount);
        uint256 supplyBefore = IERC20(token).totalSupply();
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(token, abi.encodeCall(ISuperstateToken.offchainRedeem, (amount)));
        _execute(token, amount, posts);
        assertEq(supplyBefore - IERC20(token).totalSupply(), amount);
    }

    function test_Mainnet_SPKCCAfterIssuerEnablesUSDC() public {
        _spiko(true);
    }

    function test_Mainnet_SPKCCRejectsCurrentlyUnsupportedUSDC() public {
        _spiko(false);
    }

    function _spiko(bool enableOutput) internal {
        address token = 0x4f33aCf823E6eEb697180d553cE0c710124C8D59;
        address redemption = 0xDA5599f04e9b437C8394b0c2BC68B502A66ebFe8;
        address authority = 0x344278aff344d6fb960705dc18a4912221608472;
        address admin = 0x4EAA52B6280593a8820C45cE38f974290Ae52Cea;
        // Group 6 is the existing holder group. The active authority administrator enrolls
        // both contracts; no new caller permissions or modified issuer code are introduced.
        vm.startPrank(admin);
        ISpikoPostAuthority(authority).addGroup(lane, 6);
        ISpikoPostAuthority(authority).addGroup(adapter, 6);
        if (enableOutput) ISpikoPostAdmin(redemption).registerOutput(token, USDC, true);
        vm.stopPrank();

        uint256 amount = ISpikoRedemption(redemption).minimum(token);
        if (amount == 0) amount = 100 * 10 ** IERC20Metadata(token).decimals();
        _configure(token, amount);
        bytes32 salt = keccak256("executor redemption");
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(
            token,
            abi.encodeWithSignature(
                "transferAndCall(address,uint256,bytes)", redemption, amount, abi.encode(USDC, salt)
            )
        );
        bytes32 id = keccak256(abi.encodePacked(adapter, token, USDC, amount, salt));
        if (enableOutput) {
            uint256 beforeBalance = IERC20(token).balanceOf(redemption);
            _execute(token, amount, posts);
            (ISpikoRedemption.Status status, uint48 deadline) = ISpikoRedemption(redemption).details(id);
            assertEq(uint256(status), uint256(ISpikoRedemption.Status.PENDING));
            assertGt(deadline, block.timestamp);
            assertEq(IERC20(token).balanceOf(redemption) - beforeBalance, amount);
        } else {
            IMerkleAdapter.Action[] memory actions = _prepare(token, amount, posts);
            vm.expectRevert(bytes("Input/Output pair is not authorized"));
            _runRecipe(actions, posts);
            assertEq(IERC20(token).balanceOf(lane), amount);
            assertEq(IERC20(token).balanceOf(adapter), 7);
            assertEq(IERC20(USDC).balanceOf(recipient), 0);
            (ISpikoRedemption.Status status,) = ISpikoRedemption(redemption).details(id);
            assertEq(uint256(status), uint256(ISpikoRedemption.Status.NULL));
        }
    }

    function _securitizeNotice(address token) internal {
        address redemptionWallet = 0xbb543C77436645C8b95B64eEc39E3C0d48D4842b;
        uint256 amount = 10 ** IERC20Metadata(token).decimals();
        _permissionSecuritize(token, amount, false);
        _configure(token, amount);
        uint256 beforeBalance = IERC20(token).balanceOf(redemptionWallet);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(token, abi.encodeCall(IERC20.transfer, (redemptionWallet, amount)));
        _execute(token, amount, posts);
        assertEq(IERC20(token).balanceOf(redemptionWallet) - beforeBalance, amount);
    }

    function _permissionSecuritize(address token, uint256 amount, bool qualified) internal {
        address service = IDSServiceConsumer(token).getDSService(4);
        address admin = IOwnable(service).owner();
        string memory investor = "executor-post-mainnet";
        vm.startPrank(admin);
        IDSRegistryService(service).registerInvestor(investor, "");
        IDSRegistryService(service).setCountry(investor, "US");
        IDSRegistryService(service).setAttribute(investor, 1, 1, type(uint256).max, "");
        IDSRegistryService(service).setAttribute(investor, 2, 1, type(uint256).max, "");
        if (qualified) IDSRegistryService(service).setAttribute(investor, 4, 1, type(uint256).max, "");
        IDSRegistryService(service).addWallet(lane, investor);
        IDSRegistryService(service).addWallet(adapter, investor);
        vm.stopPrank();
        address compliance = IDSServiceConsumer(token).getDSService(8);
        address config = IDSServiceConsumer(compliance).getDSService(256);
        uint256 originalTime = block.timestamp;
        vm.warp(originalTime - IDSComplianceConfigurationService(config).getUSLockPeriod() - 1);
        vm.startPrank(admin);
        IDSecuritizeToken(token).issueTokens(lane, amount);
        IDSecuritizeToken(token).issueTokens(adapter, 7);
        vm.stopPrank();
        vm.warp(originalTime);
    }

    function _installNFTReceiver() internal {
        // Real ERC721 receiver capability is required for issuer safe-minted withdrawal NFTs.
        address receiver = address(new PostActionERC721Holder());
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = IERC721Receiver.onERC721Received.selector;
        CapabilitiesRegistry(IMerkleAdapter(adapter).CAPABILITIES_REGISTRY())
            .whitelistCapability(adapter, receiver, selectors);
        MerkleAdapter(payable(adapter)).addCapability(receiver);
    }

    function _figure(address token) internal {
        uint256 amount = 10 ** IERC20Metadata(token).decimals();
        _configure(token, amount);
        address wylds = IERC4626(token).asset();
        uint256 output = IERC4626(token).previewRedeem(amount);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](2);
        posts[0] = _action(token, abi.encodeCall(IERC4626.redeem, (amount, adapter, adapter)));
        posts[1] = _action(wylds, abi.encodeCall(IFigureYieldVault.requestRedeem, (output)));
        _execute(token, amount, posts);
        (uint256 shares, uint256 assets,) = IFigureYieldVault(wylds).pendingRedemptions(adapter);
        assertEq(shares, output);
        assertGt(assets, 0);
    }

    function _infinifi(address token, uint32 epochs) internal {
        address gateway = 0x3f04b65Ddbd87f9CE0A2e7Eb24d80e7fb87625b5;
        address module = 0x7092A43aE5407666C78dBEA657a1891f42b3dFcc;
        _configure(token, 1 ether);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](2);
        posts[0] = _action(token, abi.encodeCall(IERC20.approve, (gateway, 1 ether)));
        posts[1] = _action(gateway, abi.encodeCall(IInfiniFiGateway.startUnwinding, (1 ether, epochs)));
        _execute(token, 1 ether, posts);
        assertGt(IInfiniFiUnwindingModule(module).balanceOf(adapter, block.timestamp), 0);
    }

    function _midas(address token, address redemptionVault, address outputToken) internal {
        _permissionMidas(redemptionVault);
        (address configuredFeed,,,) = IMidasRedemptionVault(redemptionVault).tokensConfig(outputToken);
        if (configuredFeed == address(0)) {
            address[] memory paymentTokens = IMidasPostVault(redemptionVault).getPaymentTokens();
            if (paymentTokens.length == 0) {
                // mBASIS currently has no redemption output enabled. Exercise its real governance
                // configuration path explicitly; this is not a claim that it is redeemable as-is.
                _grantMidas(
                    IMidasPostVault(redemptionVault).accessControl(),
                    IMidasPostVault(redemptionVault).vaultRole(),
                    address(this)
                );
                IMidasPostVault(redemptionVault)
                    .addPaymentToken(
                        outputToken, IMidasRedemptionVault(redemptionVault).mTokenDataFeed(), 0, type(uint256).max, true
                    );
            } else {
                outputToken = paymentTokens[0];
            }
        }
        uint256 amount = IMidasPostVault(redemptionVault).minAmount();
        if (amount < 1 ether) amount = 1 ether;
        _configure(token, amount);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](2);
        posts[0] = _action(token, abi.encodeCall(IERC20.approve, (redemptionVault, amount)));
        posts[1] = _action(redemptionVault, abi.encodeCall(IMidasRedemptionVault.redeemRequest, (outputToken, amount)));
        vm.recordLogs();
        _execute(token, amount, posts);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        // Midas revisions vary in event indexing. Resolve candidates against live request storage.
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != redemptionVault) continue;
            for (uint256 j = 1; j < logs[i].topics.length; ++j) {
                if (_isMidasRequest(redemptionVault, uint256(logs[i].topics[j]), outputToken, amount)) found = true;
            }
            for (uint256 j; j + 32 <= logs[i].data.length; j += 32) {
                bytes memory data = logs[i].data;
                uint256 candidate;
                assembly ("memory-safe") { candidate := mload(add(add(data, 32), j)) }
                if (_isMidasRequest(redemptionVault, candidate, outputToken, amount)) found = true;
            }
        }
        assertTrue(found, "issuer pending request missing");
    }

    function _centrifuge(address token) internal {
        _permissionCentrifuge(token, lane);
        _permissionCentrifuge(token, adapter);
        uint256 amount = 10 ** IERC20Metadata(token).decimals();
        address vault = IERC7575Share(token).vault(USDC);
        _configure(token, amount);
        IMerkleAdapter.Action[] memory posts = new IMerkleAdapter.Action[](1);
        posts[0] = _action(vault, abi.encodeCall(IAsyncRedeemVault.requestRedeem, (amount, adapter, adapter)));
        _execute(token, amount, posts);
        assertEq(IAsyncRedeemVault(vault).pendingRedeemRequest(0, adapter), amount);
    }

    function _configure(address token, uint256 amount) internal {
        OracleRegistry(registry).setOracle(lane, token, address(new PostActionMainnetPrice()));
        vm.startPrank(adapter);
        LiquidLaneConnector(lane).addTokenToRedeem(token);
        LiquidLaneConnector(lane).setMaxAssetsPerDuration(token, type(uint256).max, 1 days);
        vm.stopPrank();
        deal(USDC, adapter, 1);
        _seed(token, lane, amount);
        _seed(token, adapter, 7);
    }

    function _seed(address token, address holder, uint256 amount) internal {
        if (IERC20(token).balanceOf(holder) == amount) return;
        // Centrifuge share balances are packed into uint128; stdStorage cannot safely deal them.
        (bool centrifuge,) = token.staticcall(abi.encodeWithSignature("hook()"));
        if (centrifuge) {
            vm.record();
            IERC20(token).balanceOf(holder);
            (bytes32[] memory reads,) = vm.accesses(token);
            bytes32 original = vm.load(token, reads[0]);
            vm.store(token, reads[0], bytes32((uint256(original) & ~uint256(type(uint128).max)) | amount));
        } else {
            deal(token, holder, amount);
        }
        assertEq(IERC20(token).balanceOf(holder), amount);
    }

    function _execute(address token, uint256 amount, IMerkleAdapter.Action[] memory posts) internal {
        IMerkleAdapter.Action[] memory actions = _prepare(token, amount, posts);
        _runRecipe(actions, posts);
        assertEq(IERC20(token).balanceOf(adapter), 7, "pre-existing RWA inventory changed");
        assertEq(IERC20(token).balanceOf(lane), 0, "connector RWA remains");
        assertEq(IERC20(USDC).balanceOf(recipient), fundingAmount, "swap output missing");
    }

    function _prepare(address token, uint256 amount, IMerkleAdapter.Action[] memory posts)
        internal
        returns (IMerkleAdapter.Action[] memory actions)
    {
        fundingAmount = LiquidLaneConnector(lane).getAmountOut(token, amount);
        assertGt(fundingAmount, 0);
        deal(USDC, adapter, fundingAmount);
        actions = new IMerkleAdapter.Action[](2);
        actions[0] = _action(USDC, abi.encodeCall(IERC20.approve, (lane, fundingAmount)));
        for (uint256 i = 36; i < 68; ++i) {
            actions[0].dataMask[i] = 0xff;
        }
        actions[1] = _action(
            lane,
            abi.encodeWithSignature(
                "swap((address,address,uint256,uint256))",
                ILiquidLaneConnector.Swap(recipient, token, amount, fundingAmount)
            )
        );
        uint256 count = actions.length + posts.length;
        uint256 width = 1;
        uint256 depth;
        while (width < count) {
            width *= 2;
            ++depth;
        }
        bytes32[] memory tree = new bytes32[](2 * width);
        bytes32[] memory leaves = new bytes32[](posts.length);

        for (uint256 i; i < count; ++i) {
            bytes32 leaf = _leaf(i < actions.length ? actions[i] : posts[i - actions.length]);
            tree[width + i] = leaf;
            MerkleAdapter(payable(adapter)).grantRole(leaf, executor);
            if (i >= actions.length) leaves[i - actions.length] = leaf;
        }
        for (uint256 i = width - 1; i > 0; --i) {
            bytes32 a = tree[i * 2];
            bytes32 b = tree[i * 2 + 1];
            tree[i] = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        }
        for (uint256 i; i < count; ++i) {
            bytes32[] memory proof = new bytes32[](depth);
            uint256 index = width + i;
            for (uint256 j; j < depth; ++j) {
                proof[j] = tree[index ^ 1];
                index /= 2;
            }
            if (i < actions.length) actions[i].proof = proof;
            else posts[i - actions.length].proof = proof;
        }
        RootRegistry(roots).setRoot(adapter, tree[1]);
        MerkleAdapter(payable(adapter)).acceptRoot(tree[1]);
        _setRecipe(token, amount, actions, leaves);
    }

    function _setRecipe(address token, uint256 amount, IMerkleAdapter.Action[] memory actions, bytes32[] memory leaves)
        internal
    {
        ExecutingRecipe.Builder memory builder = ExecutingRecipe.start(40);
        IRecipeExecutor.Value memory amountValue = builder.literal(amount);
        IRecipeExecutor.Value memory fundingValue = builder.literal(fundingAmount);
        _approve = builder.approve(USDC, lane, _leaf(actions[0]), fundingValue);
        bytes32[] memory swapLeaves = new bytes32[](1);
        swapLeaves[0] = _leaf(actions[1]);
        IRecipeExecutor.Value memory initialRwa = builder.balance(token, adapter);
        {
            IRecipeExecutor.Value memory cash = builder.balance(USDC, adapter);
            _swap = builder.manage(swapLeaves, builder.literal(1));
            IRecipeExecutor.Value memory swappedRwa = builder.balance(token, adapter);
            builder.check(
                IRecipeExecutor.Operation.Equal,
                builder.binary(IRecipeExecutor.Operation.Subtract, swappedRwa, initialRwa),
                amountValue
            );
            builder.check(
                IRecipeExecutor.Operation.Equal,
                builder.binary(IRecipeExecutor.Operation.Subtract, cash, builder.balance(USDC, adapter)),
                fundingValue
            );
        }
        _clear = builder.approve(USDC, lane, _leaf(actions[0]), builder.literal(0));
        _redeem = builder.manage(leaves, builder.literal(1));
        builder.check(IRecipeExecutor.Operation.Equal, builder.balance(token, adapter), initialRwa);
        IRecipeExecutor.Recipe memory recipe = builder.finish();
        _recipeLength = ExecutingRecipe.runtimeSteps(recipe).length;
        _recipe = abi.encode(recipe);
        RecipeExecutor(executor).setRecipe(recipe);
    }

    function _runRecipe(IMerkleAdapter.Action[] memory actions, IMerkleAdapter.Action[] memory posts) internal {
        bytes[] memory runtime = new bytes[](_recipeLength);
        runtime[_approve] = abi.encode(IRecipeExecutor.Permission(actions[0].dataMask, actions[0].proof));
        runtime[_clear] = runtime[_approve];
        IMerkleAdapter.Action[] memory swap = new IMerkleAdapter.Action[](1);
        swap[0] = actions[1];
        runtime[_swap] = abi.encode(swap);
        runtime[_redeem] = abi.encode(posts);
        RecipeExecutor(executor).execute(abi.decode(_recipe, (IRecipeExecutor.Recipe)), new uint256[](0), runtime);
    }

    function _action(address target, bytes memory data) internal pure returns (IMerkleAdapter.Action memory) {
        return IMerkleAdapter.Action(target, 0, data, new bytes(data.length), new bytes32[](0));
    }

    function _leaf(IMerkleAdapter.Action memory action) internal pure returns (bytes32) {
        bytes memory masked = new bytes(action.data.length);
        for (uint256 i; i < masked.length; ++i) {
            masked[i] = action.data[i] & ~action.dataMask[i];
        }
        return keccak256(
            bytes.concat(keccak256(abi.encode(action.target, bytes1(0), keccak256(action.dataMask), keccak256(masked))))
        );
    }

    function _isMidasRequest(address redemptionVault, uint256 id, address outputToken, uint256 amount)
        internal
        view
        returns (bool)
    {
        try IMidasRedemptionVault(redemptionVault).redeemRequests(id) returns (
            address sender, address tokenOut, uint8 status, uint256 amountMToken, uint256, uint256
        ) {
            return
                sender == adapter && tokenOut == outputToken && status == 0 && amountMToken > 0
                    && amountMToken <= amount;
        } catch {
            return false;
        }
    }

    function _permissionCentrifuge(address token, address holder) internal {
        address hook = ICentrifugePostShare(token).hook();
        vm.prank(0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f);
        (bool ok,) =
            hook.call(abi.encodeWithSignature("updateMember(address,address,uint64)", token, holder, type(uint64).max));
        if (!ok) {
            vm.prank(0xEC3582fcDc34078a4B7a8c75a5a3AE46f48525aB);
            (ok,) = hook.call(
                abi.encodeWithSignature("updateMember(address,address,uint64)", token, holder, type(uint64).max)
            );
        }
        assertTrue(ok, "Centrifuge member enrollment failed");
    }

    function _permissionMidas(address redemptionVault) internal {
        address acl = IMidasPostVault(redemptionVault).accessControl();
        if (IMidasPostVault(redemptionVault).greenlistEnabled()) {
            bytes32 role = IMidasPostVault(redemptionVault).greenlistedRole();
            _grantMidas(acl, role, adapter);
            _grantMidas(acl, role, lane);
        }
        bytes32 pauseRole = IMidasPostVault(redemptionVault).pauseAdminRole();
        if (IMidasPostVault(redemptionVault).paused()) {
            _grantMidas(acl, pauseRole, address(this));
            IMidasPostVault(redemptionVault).unpause();
        }
        if (IMidasPostVault(redemptionVault).fnPaused(IMidasRedemptionVault.redeemRequest.selector)) {
            _grantMidas(acl, pauseRole, address(this));
            IMidasPostVault(redemptionVault).unpauseFn(IMidasRedemptionVault.redeemRequest.selector);
        }
        address feed = IMidasRedemptionVault(redemptionVault).mTokenDataFeed();
        (bool healthy,) = feed.staticcall(abi.encodeCall(IMidasDataFeed.getDataInBase18, ()));
        if (!healthy) {
            (,,, uint256 updatedAt,) = IPostChainlink(IMidasDataFeed(feed).aggregator()).latestRoundData();
            vm.warp(updatedAt + IMidasPostFeed(feed).healthyDiff() / 2);
        }
    }

    function _grantMidas(address acl, bytes32 role, address holder) internal {
        if (IAccessControlEnumerable(acl).hasRole(role, holder)) return;
        bytes32 adminRole = IAccessControlEnumerable(acl).getRoleAdmin(role);
        address admin = 0xd4195CF4df289a4748C1A7B6dDBE770e27bA1227;
        if (!IAccessControlEnumerable(acl).hasRole(adminRole, admin)) {
            admin = 0xb5CcD8dC8082467849eE008d4242f7b3b569EF05;
        }
        assertTrue(IAccessControlEnumerable(acl).hasRole(adminRole, admin));
        vm.prank(admin);
        IAccessControlEnumerable(acl).grantRole(role, holder);
    }
}

contract PostActionMainnetPrice {
    function getPrice() external pure returns (uint256) {
        return 1e18;
    }
}

contract PostActionERC721Holder is ERC721Holder {}

interface ICentrifugePostShare {
    function hook() external view returns (address);
}

interface IMidasPostVault {
    function getPaymentTokens() external view returns (address[] memory);
    function vaultRole() external view returns (bytes32);
    function addPaymentToken(address token, address feed, uint256 fee, uint256 allowance, bool stable) external;
    function accessControl() external view returns (address);
    function minAmount() external view returns (uint256);
    function greenlistEnabled() external view returns (bool);
    function greenlistedRole() external view returns (bytes32);
    function pauseAdminRole() external view returns (bytes32);
    function paused() external view returns (bool);
    function unpause() external;
    function fnPaused(bytes4 selector) external view returns (bool);
    function unpauseFn(bytes4 selector) external;
}

interface IMidasPostFeed {
    function healthyDiff() external view returns (uint256);
}

interface IPostChainlink {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

interface ILidoPostQueue {
    function getWithdrawalRequests(address owner) external view returns (uint256[] memory);
}

interface IOpenEdenPostExpress {
    function kycManager() external view returns (address);
    function redeemMinimum() external view returns (uint256);
}

interface IOpenEdenPostKyc {
    function WHITELIST_ROLE() external view returns (bytes32);
    function grantKyc(address holder) external;
}

interface IParetoPostAdmin {
    function setKeyringParams(address keyring, uint256 policy) external;
}

interface ISuperstatePostAllowList {
    function setProtocolAddressPermission(address holder, string calldata symbol, bool allowed) external;
}

interface ISpikoPostAuthority {
    function addGroup(address holder, uint8 group) external;
}

interface ISpikoPostAdmin {
    function registerOutput(address input, address output, bool enable) external;
}
