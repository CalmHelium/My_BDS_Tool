At present, this project provides basic automation for **Minecraft Bedrock Dedicated Server (BDS)** management. It can automatically:

* Shut down the Minecraft BDS server.
* Back up the server world/save data.
* Restart the BDS server after the backup is completed.
* Detect an existing BDS process or launch a new BDS instance based on the configured **port** and **file path**.
* Read the **world name** and **network port** from the BDS server's existing `server.properties` file.
* Store backup files in a user-specified directory.
* Generate an `.ini` configuration file at runtime, allowing users to customize the program's settings.
* Perform scheduled backups using either **time-based** or **cycle-based** modes.
* Automatically remove older backups when the number of stored backups exceeds the configured limit.

The project is primarily designed to provide a simple and automated way to manage Minecraft BDS backups while minimizing manual server maintenance.
