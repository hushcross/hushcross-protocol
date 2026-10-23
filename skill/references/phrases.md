# Command phrases

What users typically say, and the plan command to run first. Always plan first; add `--confirm` only per the hard rules.

| User says (中文) | User says (English) | Plan command |
|---|---|---|
| 检查隐私钱包能不能用 | Is HushCross ready? | `hcx preflight` |
| 我的隐私余额 / 金库里有多少 | My private balance | `hcx balance` |
| 存 0.5 BNB 进隐私金库 | Deposit 0.5 BNB into my vault | `hcx deposit --asset BNB --amount 0.5` |
| 存 100 U 到金库 | Put 100 USDT in the vault | `hcx deposit --asset USDT --amount 100` |
| 私密转 0.1 BNB 给 0xAbc… | Send 0.1 BNB privately to 0xAbc… | `hcx send --to 0xAbc… --asset BNB --amount 0.1` |
| 用隐私转账给 @alice 20 U | Pay @alice 20 USDT privately | `hcx send --to alice --asset USDT --amount 20` |
| 半小时内随机时间再发出去 | Delay it up to 30 minutes | add `--delay 30` |
| 从金库取 0.5 BNB 回钱包 | Withdraw 0.5 BNB to my wallet | `hcx withdraw --asset BNB --amount 0.5` |
| 我怎么私密收款 / 我的 Hush ID | How do I receive privately? | `hcx receive` |
| 注册收款名 bob | Claim the Hush ID bob | `hcx name claim --name bob` |
| 有人给我转账了吗 | Did I receive anything? | `hcx incoming` |
| 发个 3 人拼手气红包，共 60 U | Make a 3-packet red packet, 60 USDT | `hcx gift create --asset USDT --unit 20 --units 3 --mode group --packets 3` |
| 发一个 0.1 BNB 红包，留言"生日快乐" | One 0.1 BNB gift saying "Happy birthday" | `hcx gift create --asset BNB --unit 0.1 --message '生日快乐'` |
| 领这个红包到我的金库 | Claim this gift link to my vault | `hcx gift claim --link <link>` |
| 收回过期没领的红包 | Take back unclaimed gifts | `hcx gift list` → `hcx gift reclaim --id <gift>` |
| 现在有哪些打新 / 发售 | Which token sales are open? | `hcx launch list` |
| 在 7 号发售出价 0.02，最多花 100 U | Bid 0.02 in sale 7, max 100 USDT | `hcx launch bid --sale 7 --price 0.02 --max-spend 100` |
| 领取我的打新代币 | Claim my sale tokens | `hcx launch bids` → `hcx launch claim --bid <id>` |
| 暗池有哪些交易对 | Dark pool markets | `hcx book pairs` |
| 暗池挂单 610 买 0.5 BNB | Dark pool buy 0.5 WBNB at 610 | `hcx book order --pair 1 --side buy --price 610 --amount 0.5` |
| 没成交的部分顺延到下一轮 | Roll unfilled into the next batch | add `--rollover` |
| 领取暗池成交 | Claim my dark pool fills | `hcx book orders` → `hcx book claim --order <id>` |
| 从金库捐 20 U 给这个筹款 | Donate 20 USDT from the vault | `hcx give donate --campaign <id> --unit 20` |
| 捐款要一个收据 | With a private receipt | add `--receipt` |
| 筹款失败了，退我的捐款 | Refund my donation | `hcx give mine` → `hcx give refund --donation <id>` |
| 一步帮我私密转 35 U 给 @alice，钱不够就从钱包补 | Plan up to 35 USDT for @alice; show the actual supported amount | `hcx auto send --to alice --asset USDT --amount 35` |
| 计划继续某个任务 | Plan to resume one pending job | `hcx auto run --id <job>` (plan; execution also needs `--confirm`) |
| 查看钱包未确认记录 | Inspect unresolved wallet outcomes | `hcx wallet pending` |
| 核验用户提供的已发送交易 | Check the user-identified sent transaction | `hcx wallet reconcile --request-id <id> --tx-hash <hash>` (RPC-only plan) |
| 用现有票据恢复中断任务 | Recover interrupted funding from existing notes | `hcx auto recover --id <job>` (local-recovery plan, never resubmits) |
| 用户已核实未发送 | User verified the App order ended without sending | `hcx wallet discard --request-id <id>` (plan only; never infer not-sent) |
| 生成一个收款链接，100 U | Make a pay link for 100 USDT | `hcx request create --asset USDT --unit 100` |
| 以后每周五自动私密转 20 U 给 @alice | Every Friday pay @alice 20 USDT privately | see [autonomy.md](autonomy.md) |

Pair, sale, campaign and job IDs come from the corresponding list commands; never guess them.
For the 35 USDT example, the plan may move only 20 USDT before fees and leave 15 untouched. Do not claim an exact
35 USDT transfer. Recurring requests are not permission to bypass per-preview human confirmation; see autonomy.md.

## License

CC-BY-4.0, attributed to HushCross. See ../LICENSE.
