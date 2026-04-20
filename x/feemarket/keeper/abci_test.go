package keeper_test

import (
	"fmt"

	storetypes "cosmossdk.io/store/types"
	"github.com/evmos/evmos/v12/x/feemarket/types"
)

func (suite *KeeperTestSuite) TestEndBlock() {
	testCases := []struct {
		name         string
		NoBaseFee    bool
		malleate     func()
		expGasWanted uint64
	}{
		{
			"baseFee nil",
			true,
			func() {},
			uint64(0),
		},
		{
			"pass",
			false,
			func() {
				meter := storetypes.NewGasMeter(uint64(1000000000))
				suite.ctx = suite.ctx.WithBlockGasMeter(meter)
				suite.app.FeeMarketKeeper.SetTransientBlockGasWanted(suite.ctx, 5000000)
			},
			uint64(2500000),
		},
	}
	for _, tc := range testCases {
		suite.Run(fmt.Sprintf("Case %s", tc.name), func() {
			suite.SetupTest() // reset
			params := suite.app.FeeMarketKeeper.GetParams(suite.ctx)
			params.NoBaseFee = tc.NoBaseFee
			err := suite.app.FeeMarketKeeper.SetParams(suite.ctx, params)
			suite.Require().NoError(err)

			tc.malleate()
			suite.app.FeeMarketKeeper.EndBlock(suite.ctx)
			gasWanted := suite.app.FeeMarketKeeper.GetBlockGasWanted(suite.ctx)
			suite.Require().Equal(tc.expGasWanted, gasWanted, tc.name)
		})
	}
}

// TestEndBlock_NoParamsInStore verifies that GetParams falls back to
// DefaultParams when the params row is absent (matching cosmos/evm upstream).
// Without that fallback EndBlock would dereference a nil *big.Int inside
// MinGasMultiplier.Mul and panic, as observed by ./app/ante/cosmos.
func (suite *KeeperTestSuite) TestEndBlock_NoParamsInStore() {
	suite.SetupTest()

	storeKey := suite.app.GetKey(types.StoreKey)
	suite.Require().NotNil(storeKey)
	suite.ctx.KVStore(storeKey).Delete(types.ParamsKey)
	suite.Require().False(suite.app.FeeMarketKeeper.GetParams(suite.ctx).MinGasMultiplier.IsNil())

	meter := storetypes.NewGasMeter(uint64(1_000_000_000))
	suite.ctx = suite.ctx.WithBlockGasMeter(meter)
	suite.app.FeeMarketKeeper.SetTransientBlockGasWanted(suite.ctx, 5_000_000)

	suite.Require().NotPanics(func() {
		suite.Require().NoError(suite.app.FeeMarketKeeper.EndBlock(suite.ctx))
	})
	// 5_000_000 * DefaultMinGasMultiplier (0.5) = 2_500_000.
	suite.Require().Equal(uint64(2_500_000), suite.app.FeeMarketKeeper.GetBlockGasWanted(suite.ctx))
}
