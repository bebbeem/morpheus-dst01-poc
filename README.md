# Morpheus DST-01 -- Foundry PoC (public filing repo content)

Reproducible exploit PoC for the Morpheus bug bounty report DST-01
(Distributor counts a donated aUSDT transfer as USDT-pool yield, diverting
the daily MOR tranche). One test, one command, no setup beyond an RPC URL.

## Run

```
forge test
```

Expected: 1 passed, 0 failed.

- Test: `test_DST01_VerdictCorrected_ForwardOnly_D350` in
  `test/DST01VerdictCorrected.t.sol`
- Fork: Ethereum mainnet, block 26314439, RPC `https://eth.drpc.org`
  (hard-coded in the test; no key needed; the RPC serves archive state
  at this block)
- Attacker: fresh unprivileged address, no privileged accounts anywhere
- Assertions (all pass): attacker gain 522.264991627677235748 MOR
  (>= 400); honest stETH staker pending 167.67 MOR in the attack run vs
  224.12 MOR in the control run (strictly lower, loss 56.45 MOR); pool
  diverted 714.089204729466042112 MOR (>= 700)
- Attacker net +USD 62.59 per day (gain USD 412.58 minus the 350 aUSDT
  donation costing USD 349.99); 14-day cycle: 9,997.25 MOR diverted,
  attacker net +USD 876.26

## Notes

- All figures are for pinned block 26314439. The pool-diversion
  assertion passes by only +14.09 MOR (+2.0%) at D=350 on this block;
  the numbers are block-specific, not general claims.
- The measured window contains one daily Lido rebase (0.4279 stETH,
  97.83% of the total yield in the window).
- MOR at USD 0.79 per MOR from Uniswap pair
  0x54eB9B9b4Ae5febAEA277d93d11fC1B93eb503df (liquidity USD 9,046.96,
  thin; on-chain MOR amounts are exact, USD figures are estimates).
- Targets (Appendix A, Ethereum mainnet): Distributor
  0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A (DistributorV2 v2) and
  DepositPool USDT 0x3B51989212BEdaB926794D6bf8e9E991218cf116
  (DepositPool v7), tested through the listed proxies at the current
  implementation.
