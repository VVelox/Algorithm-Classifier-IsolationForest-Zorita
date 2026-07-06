# Algorithm-Classifier-IsolationForest-Zorita

A storage mechanism for Isolation Forest data for training.

Training Isolation Forest models of course requires data and this module aims to provide a
structured mechanism for doing so.

The base idea is it works something like this...

`$basedir/$slug/$set/$date/$hour/`

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

- `$slug` :: This is a orginizational bit. The name needs to match the regexp.
-- regex :: `^[A-Za-z0-9\-\_\@\=\+]+$`

- `$set` :: This is a data set in question. The name needs to match the regexp.
-- regex :: `^[A-Za-z0-9\-\_\@\=\+]+$`

- `$date` :: This is a current datestamp formated like `%Y-%m-%d`.

- `$hour` :: The current hour formated as `%H`.

The set directory contains several files.

- `info.json` :: Information for that set.
- `iforest_model.json` :: The primary rendered model. Built by reading the training window back
  (see `read_back`) and fitting an `Algorithm::Classifier::IsolationForest` configured from
  `info.json`, then saving it here. Rebuilding the model simply re-runs that against the current data.

`info.json` contains the following keys...

- `tags` :: A array of names for each column.
- `days back` :: When training a model, how many days it should include. Generally will want this to be a
  multiple of 7 to ensure you have a entire week without any gaps.

The rest are hyper-parameters passed straight through to the Isolation Forest module when its
`new` is called at model build time.

- `n_trees` :: Number of trees in the forest.
- `sample_size` :: Subsample size drawn per tree.
- `max_depth` :: Maximum tree depth. `null` to derive it from `sample_size`.
- `seed` :: RNG seed, so builds are reproducible.
- `mode` :: `axis` (classic Isolation Forest) or `extended` (Extended Isolation Forest). Must be
  `extended` for `extension_level` to take effect.
- `extension_level` :: Extended Isolation Forest extension level. Only meaningful when `mode` is `extended`.
- `contamination` :: Expected proportion of anomalies.
- `missing` :: How missing values are handled. One of `nan`, `zero`, or `impute`.
  Note that `die` is **not** a valid choice.
- `impute_with` :: Imputation strategy/value, only used when `missing` is `impute`.
- `voting` :: Voting strategy used when scoring.


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
