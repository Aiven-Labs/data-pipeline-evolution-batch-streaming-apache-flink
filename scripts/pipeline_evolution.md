Let's start with the original data pipeline

```
SELECT username, extract(hour from session_time) hour_window, count(*)
from users join sessions on users.id=sessions.user_id
group by username, extract(hour from session_time);
```

Create CDC connector
```
CREATE PUBLICATION MYUSERPUB FOR USERS;
```