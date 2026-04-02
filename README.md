# Vaccination & Reporting Transformation Logic

This repository contains example SQL taken from a larger reporting build process used to transform raw event-level data into structured reporting outputs.

## What this code is doing

The SQL in this repository forms part of a staged transformation pipeline. Its purpose is to take detailed source records, assess them against defined business rules, and produce reporting tables that can be used for downstream analysis and operational reporting.

At a high level, the process does the following:

1. **Prepares source data**  
   Raw immunisation and related event data is standardised into a format that can be processed consistently.

2. **Builds the reporting population**  
   Individuals are assessed against rule criteria such as age, timing, and schedule position to determine which records should be included in the reporting logic.

3. **Evaluates rule compliance**  
   Events are tested against rule definitions to identify whether valid doses or milestones have been met within the required time windows.

4. **Applies transformation and precedence logic**  
   Additional logic is used to handle overlaps, substitutions, rule hierarchies, and edge cases so that results are counted consistently and accurately.

5. **Aggregates results into reporting outputs**  
   Record-level logic is rolled up into reporting tables that show required items, completed items, and overall status for use in operational and analytical reporting.

6. **Applies business-rule overrides where needed**  
   As with many real-world reporting processes, some scenarios require specific overrides or post-processing updates to reflect agreed reporting rules.


This repository is intended to show how complex source data can be processed through a structured SQL pipeline and turned into reliable reporting outputs using layered transformation, validation, and business-rule logic.
