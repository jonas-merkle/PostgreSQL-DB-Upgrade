# PostgreSQL DB Upgrade

## Overview

The PostgreSQL DB Upgrade is a utility that assists in migrating PostgreSQL databases from an older version to a newer one using Docker containers. This script ensures data consistency by creating a backup of your existing database, migrating it to a new version, and re-indexing the data for the new PostgreSQL instance. The entire process uses Docker to isolate and manage PostgreSQL versions efficiently.

## What Happens During the Upgrade

1. **Backup the Data Directory**: The script first copies the contents of the existing data directory to a temporary backup location.
2. **Start PostgreSQL Old Version**: A Docker container is started with the current PostgreSQL version to verify and operate on the existing data.
3. **Create a Database Dump**: A Docker container with a newer PostgreSQL version is launched to create a full database dump of the old instance.
4. **Remove Old Data**: The existing data directory is cleared to prepare it for the new version.
5. **Start PostgreSQL New Version**: A Docker container is started with the newer PostgreSQL version, and the database dump is restored.
6. **Reindexing**: The script reindexes the database to ensure full compatibility with the new PostgreSQL version.

## How to Use It

### Prerequisites

- **Root or Sudo Privileges**: This script must be run with root privileges to ensure proper permissions.
- **Docker**: Docker must be installed and running on your machine.
- **Environment File (.env)**: A `.env` file must be present in the same directory as the script. This file should include the following variables:
  - `POSTGRES_USER`: The PostgreSQL user
  - `POSTGRES_PASSWORD`: The PostgreSQL password
  - `POSTGRES_DB`: The PostgreSQL database name

### Usage

1. Clone the repository or download the script.
2. Ensure the `.env` file is present with the correct variables.
3. Run the script as root or with sudo:

   ```bash
   sudo ./upgrade_postgresql_db.sh <path_to_data_directory> <current_postgres_version> <new_postgres_version>
   ```

   - `<path_to_data_directory>`: Path to your PostgreSQL data directory.
   - `<current_postgres_version>`: The current PostgreSQL version (e.g., `16`).
   - `<new_postgres_version>`: The new PostgreSQL version to upgrade to (e.g., `17`).

### Example

```bash
sudo ./upgrade_postgresql_db.sh /var/lib/postgresql/data 16 17
```

## Requirements and Limitations

- **Docker Installation**: Docker must be installed on the system where the script is executed.
- **Sufficient Storage**: Ensure you have enough storage for a full backup of your data directory and the database dump.
- **Network Ports**: The script runs PostgreSQL in Docker containers, which may require specific ports to be available.
- **Data Consistency**: Ensure no write operations are happening during the upgrade process. It is recommended to stop applications using the database before running the script.

## Disclaimer

**Use at Your Own Risk**: This script is provided as-is, without any warranties. Performing the upgrade is entirely at your own risk. It is highly recommended to test the upgrade process in a non-production environment first to ensure everything works as expected.

## License

This script is licensed under the **GNU General Public License v3.0**.

Copyright (C) 2024 [Jonas Merkle [JJM]](mailto:jonas@jjm.one?subject=%5BGitHub%5D%3A%20PostgreSQL%20DB%20Upgrade)

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program. If not, see [https://www.gnu.org/licenses/gpl-3.0.en.html](https://www.gnu.org/licenses/gpl-3.0.en.html).

## Troubleshooting

- **Permission Denied**: Ensure the script is run with `sudo` or as the root user.
- **Docker Not Found**: Ensure Docker is installed and properly set up.
- **Container Issues**: If the script fails to start or stop Docker containers, verify that no conflicting containers are running and that Docker has sufficient resources.

For further help or contributions, please feel free to raise an issue or submit a pull request.
