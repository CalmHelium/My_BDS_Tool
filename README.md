At present, this project provides basic automation for **Minecraft Bedrock Dedicated Server (BDS)** management. It can automatically:

* Shut down the Minecraft BDS server.
* Back up the server world/save data.
* Restart the BDS server after the backup is completed.
* Detect an existing BDS instance by its configured **network port** and **executable path**, ensuring that the process is running from the corresponding directory's `bedrock_server.exe`. If no matching instance is found, launch a new BDS instance.
* If an existing BDS instance launched from the current directory is detected, the program will display a warning and pause its own process. It will resume and restart the detection process after the user presses any key.
* Read the **level-name** and **server-port** from the BDS server's existing `server.properties` file.
* Store backup files in a user-specified directory.
* Generate an `.ini` configuration file at runtime, allowing users to customize the program's settings.
* Perform scheduled backups using either **time-based** or **cycle-based** modes.
* Automatically remove older backups when the number of stored backups exceeds the configured limit.

The project is primarily designed to provide a simple and automated way to manage Minecraft BDS backups while minimizing manual server maintenance.
