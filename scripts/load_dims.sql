create table tables (id serial, name varchar, seats int, primary key(id));

insert into tables (id, name, seats) VALUES
	(1, 'Donatello', 2),
	(2, 'Michelangelo', 4),
	(3, 'Raffaello', 4),
	(4, 'Leonardo', 8);

create table pizzas (id serial, name varchar, price int, primary key(id));

insert into pizzas (id, name, price) VALUES
	(1, 'Master Splinter', 8),
	(2, 'Shredder', 7),
	(3, 'Krang', 5),
	(4, 'Bebop and Rocksteady', 6);

create table clients (id serial, name varchar, primary key(id));

insert into clients (id, name) values 
	(1, 'Medonna'),
	(2, 'Duvid Beckham'),
	(3, 'Wall Smith'),
	(4, 'Josh Depp');


create table table_assignment (
    id serial, 
    client_id int,
	table_id int,
    in_time timestamp, 
    out_time timestamp, 
	primary key(id),
    constraint client_id_fk foreign key (client_id) references clients(id),
	constraint table_id_fk foreign key (table_id) references tables(id)
	);


insert into table_assignment(client_id, table_id, in_time, out_time) VALUES
	(1, 2, '2023-09-23 20:00:00', '2023-09-23 21:00:00'),
	(2, 4, '2023-09-23 21:00:00', null),
	(3, 2, '2023-09-23 21:00:00', null),
	(4, 1, '2023-09-23 22:00:00', null);

create table orders (
	id serial,
	table_assignment_id int,
	order_time timestamp,
	pizzas integer[],
	constraint table_assignment_id_fk foreign key (table_assignment_id) references table_assignment(id)
);

insert into orders (table_assignment_id, order_time, pizzas) VALUES
	(1, '2023-09-23 20:05:00', '{1,3,2}'),
	(3, '2023-09-23 21:04:00', '{1,1,1,1}'),
	(2, '2023-09-23 21:05:00', '{2,3,4,1,1,4}'),
	(2, '2023-09-23 21:07:00', '{1,1}'),
	(2, '2023-09-23 20:10:00', '{3}');

