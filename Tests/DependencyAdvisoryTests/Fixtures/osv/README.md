# Recorded OSV data

Everything in this directory was retrieved from OSV on **2026-10-06** and is stored verbatim.
No test touches the network; these are what the tests read instead.

| file | retrieved from | what it is |
|---|---|---|
| `querybatch-request.json` | — | The body POSTed to `https://api.osv.dev/v1/querybatch`. |
| `querybatch-response.json` | `POST https://api.osv.dev/v1/querybatch` (HTTP 200, 1,418 bytes) | The API's answer to that body, in query order. |
| `records/GHSA-*.json` | `https://osv-vulnerabilities.storage.googleapis.com/SwiftURL/all.zip` (64 records that day) | Every record in the export that names `swift-nio`, `swift-nio-http2`, `swift-nio-extras`, `swift-crypto` or `marmelroy/Zip` — 20 of the 64, three of them withdrawn. `GET https://api.osv.dev/v1/vulns/{id}` returned the same JSON for the one compared (`GHSA-g454-wj9r-jpg4`). |
| `modified_id.csv` | `https://osv-vulnerabilities.storage.googleapis.com/SwiftURL/modified_id.csv` (HTTP 200, 3,106 bytes) | The export's id list, newest modification first: `timestamp,id`, 64 lines. |

## What the recording established

- The ecosystem is `SwiftURL`, and the package name is the repository URL **without scheme and
  without `.git`**: `github.com/apple/swift-nio`. The same query with
  `https://github.com/apple/swift-nio.git` returned nothing for a version with three advisories.
- The name is **case-sensitive**: `github.com/marmelroy/Zip` at 2.1.2 returns
  GHSA-g454-wj9r-jpg4 and `github.com/marmelroy/zip` returns nothing.
- GHSA-q3g2-m552-3r9c is filed under the bare name `swift-nio-http2`, so the query by URL at
  1.43.0 does not return it and the query by bare name does. GHSA-9m44-rr2w-ppp7 is filed under
  `swift-crypto` the same way, so `github.com/apple/swift-crypto` at 4.2.0 returns nothing.
- Withdrawn records are not returned (three of the `swift-nio-http2` records at 1.19.1).
- `swift-nio` at 2.86.0 returns GHSA-cq87-8r7h-962v, GHSA-r3rc-9hpw-54v9 and
  GHSA-rj37-6j9x-74q6; at 2.103.0, nothing.

`RecordedOSVTests` holds the local matcher to the response for every query the API can answer,
and names the ones it cannot: the lower-cased URL, and each query for a package that also has a
record filed under a bare name.
