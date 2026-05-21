# Bridgeway Mainnet Redeployment Gas Ledger

Purpose: track gas for the next redeployment separately from the first smoke deployment.

Paste each successful transaction receipt under the matching section. For each tx, record:

- transaction hash
- operation
- gasUsed
- effectiveGasPrice
- l1Fee, if present
- total cost = gasUsed * effectiveGasPrice + l1Fee

## Summary

| Phase | Tx Count | Total ETH |
| --- | ---: | ---: |
| 01 Tokens | 3 | 0.000024936462 |
| 02 Vault | 18 | 0.000037702435779056 |
| 14 Sleeves | 16 | 0.000057348930924042 |
| Smoke Deposit/Redeem | 13 partial | 0.000043566567972137 |
| Total | 50 partial | 0.000163554396675235 |

## 01 Tokens

Broadcast: `broadcast/01_DeployTokens.s.sol/8453/run-latest.json`

| Tx | Operation | gasUsed | effectiveGasPrice | Cost ETH |
| --- | --- | ---: | ---: | ---: |
| `0xb777562d3f8279fe3211653596dcdfae763440234bc735e865899612f42d312b` | Deploy BGW token | 1,477,737 | 6,000,000 | 0.000008866422 |
| `0xd05478638499eb895995f65671f1114a9280b1af91b130fecf661623b97e0fa2` | Deploy BGW-GOV token | 2,630,612 | 6,000,000 | 0.000015783672 |
| `0xb74982a6e86d2b75e8e7da7f261b1df1818bf99559a9776cbe8a41ac1c172e15` | Set BGW-GOV companion | 47,728 | 6,000,000 | 0.000000286368 |

Subtotal: 4,156,077 gas, 0.000024936462 ETH.

## 02 Vault

Broadcast attempt: `broadcast/02_DeployVault.s.sol/8453/run-latest.json`

Partial success before RPC delegated-account in-flight limit:

| Tx | Operation | gasUsed | effectiveGasPrice | Cost ETH |
| --- | --- | ---: | ---: | ---: |
| `0x6a0eab869c5f4a53cea9602be17e1b6b6dec81c564d4c14fa816f48bb4938fe6` | Deploy BGWVault | 5,570,257 | 5,875,000 | 0.000032725259875 |
| `0x1ed0b0139986be7348216eda21467944f197436cf4e66e8268bb05e3d9daaccc` | Grant BGW MINTER_ROLE to vault | 51,514 | 5,875,000 | 0.000000302644750 |
| `0x0e845a44f43d275514570f19194d87d6f1219f5563d3a7d7b9684dfa328a81d7` | Grant BGW BURNER_ROLE to vault | 51,502 | 5,875,000 | 0.000000302574250 |
| `0x62e027a35cfb815b1e0f0e1a37fc1809c69b5945f762eb072d8b447d1cc9304f` | Grant BGW WHITELIST_ADMIN_ROLE to vault | 51,514 | 6,000,000 | 0.000000309084000 |
| `0xbe4f08552d1034c24d5bf0e79f706d0cebcbb576ed3a5ea7182b404b7fa82799` | Whitelist vault | 78,895 | 6,000,000 | 0.000000473370000 |
| `0x4c9d24528a445d492f9004aa5dd6bdd762046fe78862082afab63b2b688439cd` | Initialize vault in BGW-GOV | 72,394 | 6,000,000 | 0.000000434364000 |
| `0x39deb071af8bf557ac71352dedae769210cab0bcacc64df557b67af22fde027f` | Whitelist founder treasury | 78,895 | 6,000,000 | 0.000000473370000 |
| `0x9c2cbbaa0a288504514dfa28eed11bf6dc115cc87000a2ddf378a4bc9edee6c9` | Grant BGW DEFAULT_ADMIN_ROLE to Safe | 51,130 | 6,000,000 | 0.000000306780000 |
| `0x37a5b90d74999282d8807d45e458517880e7c95e38b9ff8037adb745f936b2cf` | Grant BGW PAUSER_ROLE to Safe | 51,514 | 6,000,000 | 0.000000309084000 |
| `0xb265b6abc087fc6f5e60e6676d0503f453bcda8a2c02a6bafde0186f43b4ff4e` | Grant BGW BLACKLIST_ADMIN_ROLE to Safe | 51,514 | 6,000,000 | 0.000000309084000 |
| `0xa13bccb843c77cd72bdf7225606e4142c56aabae13465bef7eb37699798e1b5e` | Grant BGW WHITELIST_ADMIN_ROLE to Safe | 51,514 | 6,001,735 | 0.000000309173376790 |
| `0x777f2832c81e94ad5c01a4034c9b19e0c83735e7faea6e364f6e6243fa0b23d5` | Grant BGW-GOV DEFAULT_ADMIN_ROLE to Safe | 51,196 | 6,000,000 | 0.000000307176000 |
| `0x84eb96fceb9c1099d31883b365af8a79f3ce9505856afa510c53e187275a6010` | Revoke BGW PAUSER_ROLE from deployer | 29,527 | 6,000,000 | 0.000000177162000 |
| `0x799879e4c12b72f7159525b5ff5ba025f0e31f578a3ca36dbe31a0c2b7330303` | Revoke BGW BLACKLIST_ADMIN_ROLE from deployer | 29,527 | 5,992,489 | 0.000000176940222703 |
| `0x3942ac0b004e880b9f9d28c5cc015b238000ad08ca0ef2f1c0419f82605bb47b` | Revoke BGW WHITELIST_ADMIN_ROLE from deployer | 29,527 | 6,000,000 | 0.000000177162000 |
| `0xd9d06cedb63d4c6950930377b198e74865d4c866f38a4f7fd2302a58e9b43a3b` | Revoke BGW DEFAULT_ADMIN_ROLE from deployer | 27,143 | 6,000,000 | 0.000000162858000 |
| `0x121c276b891d0cdec5f893bf8c0d63f82210542e29b52bbd67ce68a4354916d6` | Revoke BGW-GOV DEFAULT_ADMIN_ROLE from deployer | 27,143 | 5,391,141 | 0.000000146355304563 |
| `0x8332de775f238cf2282237d7fb9c66ab62d137d3d0bb4c0c82c5123a98e0abef` | Start BGWVault ownership transfer to Safe | 49,999 | 6,000,000 | 0.000000299994000 |

Subtotal: 6,404,705 gas, 0.000037702435779056 ETH.

## 14 Sleeves

Broadcast attempt: `broadcast/14_DeployAndWireSleeves.s.sol/8453/run-latest.json`

Partial success before RPC delegated-account in-flight limit:

| Tx | Operation | gasUsed | effectiveGasPrice | Cost ETH |
| --- | --- | ---: | ---: | ---: |
| `0x40fd83b4a97588a3175de2fa774ad9d62f5a7e547485657ede11e4cb26464978` | Deploy SleeveACbbtcWrapper | 1,996,176 | 6,000,000 | 0.000011977056000 |
| `0x26131169803154a2c9ed1573893e7bf68bad5aa268afed4d90d581dbd309502c` | Deploy AerodromeCbbtcStrategy | 3,139,001 | 6,000,000 | 0.000018834006000 |
| `0xdbb5ddccc3b19c37907fafbb6c453ff882f9adc913c04380065a9b2e388aa888` | Mark Aerodrome strategy APY | 72,295 | 6,000,000 | 0.000000433770000 |
| `0x774dc4e148b15b85be9c0ee2af5accba7e4917488b721c8989ce1a292acc795e` | Configure AERO to cbBTC compounding path | 117,182 | 5,983,137 | 0.000000702165377534 |
| `0x2d312c6ff6c9e89f71e85b218ffc1caae5bf5053e3e072dbd49da4ba61abeb5d` | Deploy BaseCBBTCYieldAdapter | 1,938,645 | 6,638,844 | 0.000012870295905380 |
| `0xaf0aed18408577f203ae77d3c616e574d321a711eeaba897949e16d503dd06b8` | Set Aerodrome strategy controller | 30,746 | 6,899,914 | 0.000000212152755844 |
| `0x8a63aab09e884271e8476ab4843a7657ad4a05a56043b36bf749feaab835791a` | Set Sleeve A wrapper yield adapter | 49,980 | 6,151,534 | 0.000000307453230320 |
| `0xbc6f442164a135d75106e54355c22169682654de815f48321baf8e6a48809d44` | Deploy SleeveBStableYieldAdapter | 1,504,246 | 6,000,000 | 0.000009025476000 |
| `0x78979257fa41514cdccf1966ef5e7b42e7a52a883a6394870ef88a5276afc4ab` | Configure Sleeve A adapter route | 78,109 | 5,539,716 | 0.000000432645283844 |
| `0xb72a30a75f8860dfa11126f423a949c9af33c9fd1064e5c5664dd73539e055db` | Configure Sleeve B adapter route | 78,121 | 6,000,000 | 0.000000468726000 |
| `0x35fe48b032e5362ebfddb6ec0ed7a293dbd1f5028c18083856d71b4279992023` | Set sleeve deposit weights | 30,010 | 5,750,812 | 0.000000172582371120 |
| `0x24d18be11942e7f08d41022416a2f30cba59877aa1c273d5373b9159ba16a7e6` | Register protected sleeve tokens | 125,037 | 6,000,000 | 0.000000750222000 |
| `0xdd8b967044a23e03b73a8a763d7c38f6cce0d5a70e07cffb58382971df5c0fbb` | Start Sleeve A wrapper ownership transfer to Safe | 48,444 | 6,000,000 | 0.000000290664000 |
| `0xb9dab04c584e048f75a5bceeac08e9071bc950e98e65574ef52692bd189091b0` | Start Aerodrome strategy ownership transfer to Safe | 48,737 | 6,000,000 | 0.000000292422000 |
| `0x804c141e6ceb2ffda3e5df675003f82f8ada46136ede646778f593504b3d50a5` | Start BaseCBBTCYieldAdapter ownership transfer to Safe | 48,413 | 6,000,000 | 0.000000290478000 |
| `0xddf0994de05da480b5334909657da6fe470edc67d1449f2dba237b37bd1ac507` | Start Sleeve B adapter ownership transfer to Safe | 48,136 | 6,000,000 | 0.000000288816000 |

Subtotal: 9,353,278 gas, 0.000057348930924042 ETH.

## Smoke Deposit/Redeem

| Tx | Operation | gasUsed | effectiveGasPrice | Cost ETH |
| --- | --- | ---: | ---: | ---: |
| `0x3617a26da080fa51b86b9c4b35830a259abd3cd7c82911b6e263396e1b0cceb0` | Whitelist deployer for smoke deposit | 78,895 | 5,750,006 | 0.000000453646723370 |
| `0x20f06b678a592e0554998abea53b5aef6120c12b6f66523528e685d535038c2c` | Approve 60 USDC to vault | 55,437 | 6,000,000 | 0.000000332622000000 |
| `0xc92c1f57368d3491c2679589c634f2a497642d85d92aa56462d1f94763bac1dc` | Deposit 60 USDC smoke test | 2,216,706 | 5,875,000 | 0.000013023147750000 |
| `0x72f3f0a1afe9c2f3d667da7828206222ee6afadce45635579f0f398f3008bae6` | Transfer 2 USDC redemption buffer to vault | 62,159 | 6,000,000 | 0.000000372954000000 |
| `0x2af6d38bd25ec04ba730de0131f5b1a26169318e3c7e69b83bb17531d384aa41` | Redeem 1 BGW smoke test | 1,844,545 | 6,000,000 | 0.000011067270000000 |
| `0x5799eda13ebb0410db299c80e69a40464e12f4acb3143517cb2a1eb10600ca29` | Redeem 45 BGW before redeploy | 2,203,032 | 6,000,000 | 0.000013218192000000 |
| `0xf12faa6b5dbcad3011644f31c88be89e76fadc3427484fb769a63879c0159ee8` | Recover idle vault USDC before redeploy | 56,243 | 6,000,000 | 0.000000337458000000 |
| `0xf1a0b6af22c41a3d093cfba8b3b5ee8207b14bd6dcf7e41a749e03f35b86e30e` | Emergency unwind Sleeve B before redeploy | 492,353 | 6,000,000 | 0.000002954118000000 |
| `0x4d3dbca540a187046150883983deaefba9d91eee5363c2a50411f7493ec4579f` | Recover Sleeve B USDC before redeploy | 56,243 | 6,000,000 | 0.000000337458000000 |
| `0x5fae02fd25a29c35dca0b5093c62f7366ad0b9a96d363b4573fbcc59255b7718` | Add USDT as trusted Sleeve A asset test | 95,739 | 6,000,000 | 0.000000574434000000 |
| `0xe06d17a634240234765a310d636bee208f636a72c91ec5718b9cbb5a74a1d6ce` | Add USDT as trusted Sleeve B asset test | 58,751 | 6,000,000 | 0.000000352506000000 |
| `0x7f160d7a4a36c450101760ca6e1ce03856eb9847609d1ecb771ead8c2339dd0f` | Add USDT as trusted Sleeve C asset test | 58,751 | 5,500,017 | 0.000000323131498767 |
| `0x41744abf18e50614998d18b36ffa8eab16eb778aadf887703566516e29508047` | Remove USDT from trusted Sleeve C asset test | 36,605 | 6,000,000 | 0.000000219630000000 |

Subtotal: 7,315,459 gas, 0.000043566567972137 ETH.
