# Lab 075: HTTPS fetches through the relay that stall

Question: in labs 073 and 074, one or two HTTPS fetches through the relay connected and finished TLS but got no
answer within the timeout. Is the relay losing data?

`run.ps1` starts one isolated machine and fetches four URLs 20 times each from the guest (HTTPS to
www.microsoft.com, www.cloudflare.com, example.com and plain HTTP to example.com), then traces a failing fetch.

## Result (2026-11-24)

80 of 80 fetches answered, so nothing failed to trace. The stall was seen once in lab 073 (one machine) and twice in
one lab 074 run that had a second GPU machine booting; it did not come back in 80 fetches here nor in the later lab
074 runs (10 of 10 HTTPS fetches). Not explained yet; kept as a regression check.
