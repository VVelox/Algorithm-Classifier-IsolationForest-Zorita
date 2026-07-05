# Algorithm-Classifier-IsolationForest-Zorita

A storage mechanism for Isolation Forest data for training.

Training Isolation Forest models of course requires data and this module aims to provide a
structured mechanism for doing so.

The base idea is it works something like this...

`$basedir/$slug/$set/$date/$hour/`

Each writer then writes to it's own file. By having a hourly directory, this ensures that
each model can be updated hourly.

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
- `iforest_model.json` :: The primary rendered model.

`info.json` contains the following keys...

- `tags` :: A array of names for each column.
- `days back` :: When training a model, how many days it should include. Generally will want this to be a
  multiple of 7 to ensure you have a entire week without any gaps.


Under the hour directory writers should write to files named `w.$writer.csv` with
writer being the name of the writer in question. A writer needs to first check `info.json`
to ensure it will be writing out it's data in the expected order to the csv. Writes to
this file should be done as appends.

`combined.csv` in the writer directory should only be creatd after the hour is passed. It contains
all the rows from each writer csv for the hour for that set.

`daily.csv` should exist under the `$date` directory and should only be created once the day has passed.
It contains all the rows from the `combined.csv` for that day for that set.
