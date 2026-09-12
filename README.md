# Nyan / DSDA-Doom Demo Regression Test
How to run the test:

# Files Needed
1) Add IWADs into `regression-test/support/wads` (`DOOM2.WAD`, `DOOM.WAD`, `HERETIC.WAD`, `HEXEN.WAD`, `PLUTONIA.wad`, `TNT.wad`). [see `readme.txt` in directory for more info].
2) Download both Junkfood 4 and Eviternity II wads and extract them into `regression-test/support/wads/EX` (they are too large for github).
3) (Optional) Add Commercial WADs into `regression-test/support/wads/EX/CM` (see `readme.txt` in directory for more info).
4) (Optional) Add Master Levels into `regression-test/support/wads/EX/CM/ML`.

>Note: Specific Commercial and Master Levels will be skipped (marked as pass) if they are not present.

# EXE Setup
1) Set up port names, nicknames, and executable paths inside `regression-test/build/ports.json`.
2) Build each new port executable in the location configured by its `exe` entry.
3) Build each old/reference executable in the location configured by its `old_exe` entry.
4) Install ruby (latest version).
5) Install parallel with `gem install parallel`.
6) Setup paths / variables in `regression-test/support/settings.json` (you may need to adjust the amount of cores to use).
7) Make sure that all overflow warnings are set to false (`0`), but overflow emulations are set to true (`1`) in `nyan-doom.cfg` / `dsda-doom.cfg` (for both exes):
```
# Overrun settings
overrun_spechit_warn             0
overrun_spechit_emulate          1
overrun_reject_warn              0
overrun_reject_emulate           1
overrun_intercept_warn           0
overrun_intercept_emulate        1
overrun_playeringame_warn        0
overrun_playeringame_emulate     1
overrun_donut_warn               0
overrun_donut_emulate            1
overrun_missedbackside_warn      0
overrun_missedbackside_emulate   1
```

# Running the test
1) Enter the `regression-test` directory
2) Run `ruby dsda-index.rb` to build the index of dsda demos.
3) Once index is complete, run `ruby dsda-sync.rb` to download all demos.
4) Run `ruby dsda-test.rb` to run the entire regression test.
5) When the test completes, `1-results.csv` and `2-failures.csv` (if there are failures) will be created in `regression-test/csv/`.

# Fixing Failures / Editing Overrides
1) Once the test is completed, if there are failures they will be created in `regression-test/csv/`.
2) The test uses `0-overrides.csv` (in `regression-test` directory) to get specific demos to run correctly (or to force a skip)
3) Open both `2-failures.csv` and `0-overrides.csv`
4) `2-failures.csv` will include a cmdline and demo folder path for easy testing and troubleshooting.
6) First, see if you can use the `IwadOverride`, `FileOverride`, or `ExtraArgs` fields to get the demo to sync
   - `IwadOverride` - rare, but sometimes the demo may be for the wrong iwad. (example: `doom2.wad`)
   - `FileOverride` - relative to the current wad folder; Each file should be separated via `,`; For external, commerical, or Master Levels, use the aliases `EX/, CM/, ML/`; The alias `demo_dir/` corresponds to the current demo folder; note that the order of the wads is the load order and will override the current `-file` arguments (example: `EX/nerve.wad, cool.wad, fix/cool.deh, demo_dir/patch.deh`).
   - `ExtraArgs` - includes any extra arguments you may need to get the demo to sync. Note that all the arguments should be surrounded by double quotes (example: `"-complevel 5 -nodeh"`)
7) If you can't get the demo to sync, than you may need to `Skip` it. There are many reasons for skipping demos, but by default the demo is still ran for regression checking, but is "skipped" in regards to marking against the test. There are cases where a demo can cause a freeze, crash, or simply takes too long to run... This takes the `Reason` column into account, which is where we specify the reason for the skip. These reasons will not run the demo at all and truly skip it: `crash`, `freeze`, `unpredictable`, `duplicate`, `ignore`, `wrong wad`, `wrong iwad`, `too long`, `bad wad`.
8) Once you fill out the fields make sure to also fill out the `Action` column with `Override` or `Skip`
9) Now copy the "fixed" row from `2-failures.csv` and paste it into `0-overrides.csv`. All CSVs follow the same column structure, so they are easy to transfer over.
10) Now in order to see if you've fixed those demos, you can re-run `dsda-test.rb` with `--failed-only` and it'll only re-test the failed demos... If specific demos then pass, they will be updated in `0-overrides.csv`.
11) `2-failures.csv` will be deleted if all the failures have been resolved.

# Re-indexing / Re-syncing
- If you want to grab any new demos, following the current dsda index you have, you can re-run `dsda-sync.rb` and it will only grab new demos.
- However, if you need to grab demos from new wads, you will have to re-run `dsda-index.rb` to index the new wad first.

# Options for Sync and Test
- `dsda-index.rb`
  - `--threads <#>` Indexing threads (default 5)
  - `--per <#>` DSDA Demos Per-page (default 200)
  - `--max-retries <#>` DSDA Website HTTP Retries per page (default 5)
  - `--help` Show commands
- `dsda-sync.rb`
  - `--force` Force overwrite extracted content
  - `--skip-wads` Don't download/extract wad zips
  - `--skip-demos` Don't download/extract demo zips
  - `--failed-only` / `--retry-failed` Retry only failed demos
  - `--refresh-index` Ignore cached index and build a new one *(recommended: run dsda-index.rb)*
  - `--help` Show commands
- `dsda-test.rb`
  - Running the test without any options will run the entire test.
  - Usage:
    - `ruby dsda-test.rb [IWAD[/WAD[/DEMO_FOLDER]]] [options]`
  - Examples:
    - `ruby dsda-test.rb`
    - `ruby dsda-test.rb doom2`
    - `ruby dsda-test.rb doom2/av`
    - `ruby dsda-test.rb doom2/av/av01-123`
    - `ruby dsda-test.rb av`
    - `ruby dsda-test.rb av/av01-123` 
  - Options:
    - `--failed-only` / `--retry-failed` run only the demos that failed during the last test (see `regression-test/csv/2-failures.csv`).
    - `--fill-demo-folder` Fill missing DemoFolder values in `0-overrides.csv` and exit.
    - `--port <NAME>` Select a configured port by its full name or nickname and remember it as the active port (for example, `--port dsda-doom` or `--port dsda`).
    - `--port-name <NAME>` Override only the port name recorded in test results; this does not select different executables.
    - `--set-exe-path <PATH>` Override the new engine executable for this run.
    - `--set-old-exe-path <PATH>` Override the old/reference engine executable for this run.
    - `--help` Show commands

# Selecting a Port with dsda-start
- Run `ruby dsda-start.rb`, then enter `port` to list the configured ports.
- Enter `port <NAME>` to select a port by its full name or nickname (for example, `port nyan-doom` or `port nyan`).
- The selected port is remembered and passed to subsequent test runs.
- Enter `port --help` for the port command help.
