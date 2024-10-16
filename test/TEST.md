# How to test the `upgrade_postgres_db.sh` script?

1. Make sure you are in the root directory of this repository.
2. Check if your `.env` file contains the following:

    ```text
    POSTGRES_USER='test-user'
    POSTGRES_PASSWORD='test-password'
    POSTGRES_DB='test-db'
    ```

3. Run:

    ```bash
    ./test/test_init.sh ./test/data 16
    ```

    This will initialize an empty PostgreSQL server data directory.
4. Run the upgrade script:

    ```bash
    sudo ./upgrade_postgresql_db.sh ./test/data 16 17
    ```

5. Start a new PostgreSQL server within a docker container:

    ```bash
    docker run -d --name PG_17_TEST -p 5432:5432 \
          -v "./test/data:/var/lib/postgresql/data" \
          -e POSTGRES_USER='test-user' \
          -e POSTGRES_PASSWORD='test-password' \
          -e POSTGRES_DB='test-db' \
          postgres:17
    ```

6. Try to connect with any SQL-client and check the content of the database. Use therefor the following connection information:
    - Host: `localhost`
    - Port: `5432`
    - User: `test-user`
    - Password: `test-password`
    - Database: `test-db`
