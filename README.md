# Algorithm-Classifier-IsolationForest-Zorita

A storage mechanism for Isolation Forest data for training.

Training Isolation Forest models of course requires data and this module aims to provide a
structured mechanism for doing so.

The base idea is it works something like this...

`$basedir/$type/$slug/$set/$date/$hour/`

Each writer then writes to it's own file. The hourly directory is what makes hourly updates
possible: it lets a model read back only part of a day rather than being forced to include a
whole day at a time.

For example, if a model trains on 7 days (168 hours), without an hourly directory the smallest
unit you could read back is a full day. That means you could only reliably reach back 6 days,
because pulling in the 7th day would also drag in everything else recorded that day, including
rows that fall outside the intended 168 hour window. With the hourly directory you can read
back exactly the hours you want, so the model can be updated hourly by reading in part of the
day-before's data without overshooting the time frame.

- `$basedir` :: This is the directory this all operates out of.
-- Default :: `/var/db/zorita/`

- `$type` :: The model backend the tree holds, either `batch` or `online`
  (default `batch`). `batch` sets are built with `Algorithm::Classifier::IsolationForest`
  and `online` sets with `Algorithm::Classifier::IsolationForest::Online`. Because it
  is the first path segment, the two backends live in side-by-side trees
  (`$basedir/batch/...` and `$basedir/online/...`) that never share slugs, sets,
  or templates — including their own `.set_templates` control directory each.
  The `zorita` command selects it with `--type`/`-t`.

- `$slug` :: This is a orginizational bit. The name needs to match the regexp.
-- regex :: `^[A-Za-z0-9\-\_\@\=\+]+$`

- `$set` :: This is a data set in question. The name needs to match the regexp.
-- regex :: `^[A-Za-z0-9\-\_\@\=\+]+$`

Note that the name regexp does not include `.`, so a `$slug` or `$set` may never
start with a dot (it may never match `^\.`). Leading-dot names are reserved for
control directories that sit next to the slugs under `$basedir` — currently just
`.set_templates` (see below) — so those directories can never collide with a
real slug or set.

- `$date` :: This is a current datestamp formated like `%Y-%m-%d`. **Batch only** —
  online sets have no `$date`/`$hour` layer (see below).

- `$hour` :: The current hour formated as `%H`. **Batch only.**

## Batch vs. online sets

The `$date`/`$hour` layers, the per-writer CSV files, the roll-ups
(`combined.csv`/`daily.csv`), and the windowed `read_back` all exist to support
**rebuilding** a batch model from stored rows. An **online** set works
differently: it stores no rows at all. It is a live
`Algorithm::Classifier::IsolationForest::Online` model served over a Unix socket,
learning each row as it arrives and dropping it — so there is nothing to roll up
and nothing to rebuild (`rebuild_model`, `read_back`, and the `combine_*` methods
croak for an online set).

An online set directory (`$basedir/online/$slug/$set/`) therefore holds no
`$date`/`$hour` subtree, and instead of a single `iforest_model.json` it holds:

- `info.json` :: the set config, as below.
- `stream.sock` :: the Unix socket the daemon listens on.
- `stream.pid` :: the running daemon's pid (double-start guard).
- `streamd.log` :: the daemon log.
- `latest.json` :: a symlink to the newest timestamped save.
- `oiforest-YYYYmmdd-HHMMSS.json` :: timestamped model saves (pruned to `--keep`).

The daemon is `Algorithm::Classifier::IsolationForest::Zorita::Online`. It resumes
from `latest.json` when present, else builds a fresh model from `info.json`, and
speaks the same JSON-lines protocol as the upstream `iforest streamd`
(`row`/`rows`/`cmd` with `ping`/`mode`/`stats`/`save`/`relearn-threshold`). See
that module's POD for the protocol.

Drive it from the CLI with the two online subcommands:

```
zorita streamd myapp stream               # run the daemon for the set
zorita streamc myapp stream -i rows.csv   # stream rows through it, print score,label
zorita streamc myapp stream --ping        # one-shot control commands
```

`zorita streamc` (and any program) can talk to the daemon through
`Algorithm::Classifier::IsolationForest::Zorita::Online::Client`, which wraps the
socket and protocol behind `row`/`rows`/`ping`/`stats`/`save`/… methods. The
upstream `iforest streamc` speaks the same protocol and works too.

The set directory contains several files.

- `info.json` :: Information for that set.
- `iforest_model.json` :: The primary rendered model. Built by reading the training window back
  (see `read_back`) and fitting an `Algorithm::Classifier::IsolationForest` configured from
  `info.json`, then saving it here. Rebuilding the model simply re-runs that against the current data.

`info.json` contains the following keys...

- `tags` :: A array of names for each column. Each name must match the same regexp as
  slugs/sets (which also keeps the comma-joined CSV header well-formed), with no duplicates.
- `days_back` :: When training a model, how many days it should include. Generally will want this to be a
  multiple of 7 to ensure you have a entire week without any gaps.
- `mungers` :: Optional. An object mapping a tag name to the input munger for that column (see
  **Input munging** below). Tags not listed here — or the key being absent entirely — are treated as
  raw and passed through unchanged.
- `type` :: Stamped in automatically by `write_info` to record the backend the set belongs to
  (`batch` or `online`); you do not normally set it by hand. If present it must match the tree the
  set lives in, so a body copied into the wrong-type tree is rejected.

The rest are hyper-parameters passed straight through to the backend when its `new` is called at
model build time. **Which apply depends on `$type`** — the two backends take different
hyper-parameters, and a key the backend does not recognize is simply not forwarded. `n_trees`,
`seed`, and `contamination` are common to both.

Shared:

- `n_trees` :: Number of trees in the forest.
- `seed` :: RNG seed, so builds are reproducible.
- `contamination` :: Expected proportion of anomalies.

`batch` only:

- `sample_size` :: Subsample size drawn per tree.
- `max_depth` :: Maximum tree depth. `null` to derive it from `sample_size`.
- `mode` :: `axis` (classic Isolation Forest) or `extended` (Extended Isolation Forest). Must be
  `extended` for `extension_level` to take effect.
- `extension_level` :: Extended Isolation Forest extension level. Only meaningful when `mode` is `extended`.
- `impute_with` :: Imputation strategy/value, only used when `missing` is `impute`.
- `voting` :: Voting strategy used when scoring. `mean` (the default) or `majority`.

`online` only:

- `window_size` :: How many most-recent points the model reflects before it forgets the oldest.
- `max_leaf_samples` :: Points a leaf accumulates before it splits.
- `growth` :: How the split requirement scales with depth. `adaptive` or `fixed`.
- `subsample` :: Per-tree probability, in `(0, 1]`, that a tree learns a given point.

- `missing` :: How missing values are handled. The legal values **differ by type**: `batch` takes
  `nan`, `zero`, or `impute`; `online` takes only `zero`. Note that `die` is **not** a valid choice
  for either.


## Input munging

The CSV stores raw numeric data (see the note at the bottom of this file), but the values a writer
is handed are not always numeric to begin with — an HTTP method is a string, a timestamp is a
formatted date, and so on. **Input munging** is how such a value is turned into the number that
actually gets written to the CSV. Munging happens on the *input* side, at write time, before the
row is appended.

A munger is attached to a tag through the optional `mungers` key in `info.json`. It is an object
keyed by tag name; each value selects a **named built-in munger** by name and carries whatever
parameters that munger needs:

```json
"tags": ["bytes", "status", "method"],
"mungers": {
  "method": { "munger": "enum", "map": { "GET": 0, "POST": 1, "PUT": 2 } }
}
```

Here `method`'s incoming string is mapped to a number by the `enum` munger before it lands in the
CSV. `bytes` and `status` have no entry in `mungers`, so they are **raw**: their values are passed
through untouched and are expected to already be clean numeric data.

The important rule: **any tag without a munger is raw.** If `mungers` is absent entirely, every tag
is raw. A raw value is inserted into the CSV verbatim, with no transformation — exactly the behavior
this project had before mungers existed. Only tags that name a munger are transformed, and only by
the built-in the munger names.

### Built-in mungers

The mungers live in
[`Algorithm::Classifier::IsolationForest::Zorita::Mungers`](lib/Algorithm/Classifier/IsolationForest/Zorita/Mungers.pm);
see its POD for the full parameter reference. Most turn one raw value into one number; a few expand
one value into several columns (`into`) or combine several input fields into one column (`from` as
a list).

Categorical / mapping:

- `enum` :: map a value to a number via an explicit `map` (with an optional numeric `default` for
  unmapped values). For low-cardinality categoricals (`proto`, `http_method`, message types).
- `frozen_freq_map` :: frequency-encode from a **precomputed** `counts` table so rare values score as
  anomalous. `mode` defaults to `neg_log_prob` (self-information); also `freq`, `log_count`, `count`.
  Add-one `smoothing` and an `unseen => 'rare'` policy handle values not in the table. For bounded,
  moderate-cardinality columns; use `hash` for unbounded ones.
- Named-map enums :: like `enum` but with the map baked in from a well-known registry, matched
  case-insensitively, with the same optional numeric `default` for unmapped values:
  `dns_rcode_enum` (`NXDOMAIN` → `3`), `dns_qtype_enum` (`AAAA` → `28`), `syslog_severity_enum` /
  `syslog_facility_enum`, `ip_proto_enum` (`tcp` → `6`), `tls_version_enum` (version → ordinal, so
  "older than expected" is monotone), `http_method_enum` / `sip_method_enum`, and
  `dhcp_msgtype_enum` (accepts both `DISCOVER` and `DHCPDISCOVER`). Where the numbers are the
  protocol's own encoding (DNS, syslog, IP proto, DHCP) a numeric input passes through unchanged.

Reply / status codes (collapse a code to its leading digit, e.g. `404` → `4`):

- `http_enum`, `smtp_enum`, `sip_enum`, `ftp_enum`, `rtsp_enum`, `nntp_enum`, `dict_enum` :: with an
  optional `strict` flag that rejects codes outside the protocol's valid range
  (HTTP/FTP/RTSP/NNTP/DICT `100`–`599`, SMTP `200`–`599`, SIP `100`–`699`).
- `gemini_enum` :: the same for Gemini's two-digit codes (`51` → `5`; strict range `10`–`69`).
- `mgcp_enum` :: the same for MGCP response codes, whose valid set has a hole — `strict` accepts
  `100`–`599` plus the package-specific `800`–`899`, rejecting the nonexistent `6xx`/`7xx`.

Booleans and bucketing:

- `bool` :: coerce to `1`/`0` — Perl truthiness, or a `true` list of values considered true.
- `bucket` :: map a number to a bucket index by ascending `bounds` (e.g. `[1024, 49152]` for
  well-known / registered / ephemeral ports).
- `quantile` :: `bucket`'s continuous sibling — piecewise-linear ECDF over ascending `bounds` taken
  from the training data's quantiles, mapping onto `[0, 1]`. The heavy-tail normalizer for when
  `log` isn't enough and `zscore` is outlier-fragile.

Numeric transforms:

- `log` :: `log(value + offset)`; `offset => 1` gives a `log1p` that tames heavy tails (bytes,
  durations, counts) and admits zero. Optional `base`.
- `scale` :: min-max normalize to `[0, 1]` given `min`/`max`, optional `clamp`.
- `zscore` :: standardize as `(value - mean) / std`.
- `clamp` :: cap a number into `[min, max]` (either bound optional).
- `num` :: parse a string as a number in `base` 2–36 (`'0x2f'` → 47), for tooling that logs flag
  words and IDs in hex.
- `bit` :: bit-level features from an integer flags word (TCP flags, DNS header flags): `mask` +
  mode `any`/`all` (bit tests → `1`/`0`), `value` (extract masked bits, shifted), or `popcount`
  (number of set bits — a Christmas-tree packet is anomalous even when each bit is common).

String shape:

- `length` :: character length of the value (absent = `0`).
- `entropy` :: Shannon entropy in bits — the randomness signal behind DGA / generated-name detection.
  XS-accelerated with a pure-Perl fallback.
- `ngram` :: mean per-gram surprisal against a precomputed n-gram `counts` table (bigrams usually) —
  `frozen_freq_map`'s sequential cousin and the strongest single gibberish detector: catches *pronounceable*
  generated names and short strings that `entropy` misses.
- `char` :: count, or (with `mode => 'ratio'`) fraction, of characters in a `class` such as
  `non_alnum`, `non_ascii`, `vowel` / `consonant`, or `xdigit`.
- `run` :: length of the longest unbroken run of characters in a `class` — longest consonant/digit
  run is a staple DGA feature that totals and entropy both miss.
- `count` :: occurrences of a literal substring `of` (with an optional `plus`), e.g. path depth from
  `/` or label count from `.`.
- `match` :: regex `pattern` to `1`/`0` (or `mode => 'count'`) — punycode labels, percent-escapes,
  IP-literal Hosts; anything `char`/`count` can't express.
- `hash` :: feature-hash a string into `buckets` (32-bit FNV-1a) for high-cardinality categoricals.
  XS-accelerated with a pure-Perl fallback.

Network addresses:

- `ip_class` :: collapse an IPv4/IPv6 address to its address-space class (global / private /
  loopback / link-local / multicast / broadcast / unspecified / reserved) — to addresses what the
  status-class enums are to reply codes. v4-mapped v6 classifies as its embedded v4.
- `cidr` :: index of the first net in a `nets` CIDR list containing the address (with an optional
  `default`) — `bucket` for address space, for encoding site-specific zones (DMZ, server VLAN,
  guest Wi-Fi) the generic `ip_class` can't know about.

Combining and composition:

- `ratio` :: first source divided by the second (`"from": ["bytes_out", "bytes_in"]`), with a
  `zero` fallback for a zero denominator — asymmetry features like exfiltration's bytes-out over
  bytes-in. Multi-input: only usable via a `from` list, so named writes only.
- `combine` :: fold several numeric sources with `op` `sum` / `diff` / `product` / `min` / `max` /
  `mean`, for totals, gaps, and extremes across fields. Multi-input like `ratio`.
- `chain` :: string pre-transforms (`lc`, `uc`, `trim`, `split` + index, regex `capture`,
  `replace`) feeding a terminal munger (`then`) — e.g. lowercase, keep the last dot-label, then
  `entropy` scores just the TLD. Works with multi-output terminals too (`into` on the chain,
  `parts` on the terminal).

Rates (backed by an external daemon):

- `eps` :: per-entity sliding-window event rates via the `iqbi-damiq` daemon from
  [Algorithm::EventsPerSecond](https://metacpan.org/pod/Algorithm::EventsPerSecond). The input value
  (plus a `prefix`) becomes a meter key; by default the munger marks one event against it and returns
  the key's current events/sec (`read` can also be `count` or `total`, `mark => 0` reads without
  marking). Because the daemon is shared, writers on many hosts marking the same keys see one
  *global* rate. Supports the multi-output `parts`/`into` form so rate+count of one key costs a
  single round trip. Connections are lazy — no daemon is needed to create or validate a set.

Time (parse a strptime `format`, then extract one `part`):

- `datetime` :: `part` is one of `epoch`, `year`, `mon`, `mday`, `hour`, `min`, `sec`, `wday`, `yday`,
  `frac_day` / `frac_week` (fraction through the day/week), or the cyclic `sin_day` / `cos_day` /
  `sin_week` / `cos_week` (continuous across the midnight/Sunday seam — prefer these for the forest).


## Set templates

`$basedir/$type/.set_templates/` is a reserved control directory holding **set
templates**: files named `$template.json`, each one a ready-made `info.json`
body. Because a slug/set may never begin with a dot, this directory can never be
confused with a slug. It lives inside the per-type root, so `batch` and `online`
keep independent template sets — which matters because a template valid for one
backend (a `voting` policy, `missing: nan`) is not necessarily valid for the
other. A template is stamped into the same-type tree it lives in.

A template lets you stamp out consistently-configured sets. When a template is
used, a new set is created under the specified slug and the specified template's
JSON is written verbatim as that set's `info.json`:

```
zorita templates                          # list template names
zorita create-set myapp http-logs http    # myapp/http-logs/info.json <- http.json
```

Creating a set this way refuses to overwrite a set that already has an
`info.json`, and fails if the named template does not exist. Template names obey
the same regexp as slugs and sets.

Under the hour directory writers should write to files named `w.$writer.csv` with
writer being the name of the writer in question. A writer needs to first check `info.json`
to ensure it will be writing out it's data in the expected order to the csv. Writes to
this file should be done as appends.

The first row of a fresh `w.$writer.csv` is a header of the `tags` names. Because the file is
only ever appended to, the header must be written only when creating the file and never re-added
on subsequent appends, so each writer file ends up with exactly one header line.

`combined.csv` in the writer directory should only be creatd after the hour is passed. It contains
all the rows from each writer csv for the hour for that set.

`daily.csv` should exist under the `$date` directory and should only be created once the day has passed.
It contains all the rows from the `combined.csv` for that day for that set.

Unlike the writer files, `combined.csv` and `daily.csv` are not appended to; they are atomically
replaced (written to a temp file and renamed) and carry a single header row of the `tags` names.

Apart from the header, every data row is raw numeric data: plain numbers separated by commas, with
no quotes, spaces, or other escaping. When combining, each data line is double checked and any line
containing non-numeric data is dropped rather than carried into `combined.csv`/`daily.csv`.
