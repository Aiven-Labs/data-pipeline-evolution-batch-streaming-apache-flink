from faker import Faker
from dateutil.relativedelta import relativedelta
from datetime import datetime
import psycopg2
import psycopg2.extras
import time

fake = Faker()

with open("tmp/postgresql_connection_uri.txt") as file:
    connection_string = file.read().strip()

try:
    conn = psycopg2.connect(connection_string, connect_timeout=2)
except psycopg2.Error as err:
    conn = None
    print(str(err))

cur = conn.cursor()

# Loading users data
print("Loading users data")
data = []

i = 0
while i < 0:
    id = i

    name = fake.name()
    browser = fake.user_agent()
    row = (id, name)
    data.append(row)

    if (i) % 10000 == 0:
        print(str(i) + "/50000")
        psycopg2.extras.execute_values(
            cur,
            """
            insert into users (id, username) values %s
            """,
            data,
        )
        data = []
    i = i + 1
data = []

i = 0
while i < 10000000:
    id = fake.random_int(min=1, max=1000)
    timestamp = fake.date_time_between(
        datetime.now() - relativedelta(years=1),
        datetime.now(),
    )
    ip_address = fake.ipv4()
    browser = fake.user_agent()
    row = (id, timestamp, ip_address, browser)
    data.append(row)

    if (i) % 10000 == 0:
        print(str(i) + "/50000")
        psycopg2.extras.execute_values(
            cur,
            """
            insert into sessions (user_id, session_time, ip_address, browser) values %s
            """,
            data,
        )
        data = []
    i = i + 1

conn.commit()
# Loading live data
print("Loading live data")
data = []
i = 0
while True:
    id = fake.random_int(min=1, max=1000)
    timestamp = datetime.now()
    ip_address = fake.ipv4()
    browser = fake.user_agent()
    row = (id, timestamp, ip_address, browser)
    data.append(row)
    if (i) % 5 == 0:

        psycopg2.extras.execute_values(
            cur,
            """
            insert into sessions (user_id, session_time, ip_address, browser) values %s
            """,
            data,
        )
        conn.commit()
        data = []
    time.sleep(0.1)
    print(".")
    i = i + 1
