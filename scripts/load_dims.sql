create table tables (id serial, name varchar, seats int, primary key(id));

insert into tables (name, seats) VALUES
	('Donatello', 2),
	('Michelangelo', 4),
	('Raffaello', 4),
	('Leonardo', 8);

create table pizzas (id serial, name varchar, price int, primary key(id));

insert into pizzas (name, price) VALUES
	('Master Splinter', 8),
	('Shredder', 7),
	('Krang', 5),
	('Bebop and Rocksteady', 6);

create table clients (id serial, name varchar, primary key(id));

insert into clients (id, name) values 
	(1, 'Medonna'),
	(2, 'Duvid Beckham'),
	(3, 'Wall Smith'),
	(4, 'Josh Depp');


create table table_assigment (
    id serial, 
    client_id int,
	table_id int,
    in_time timestamp, 
    out_time timestamp, 
	primary key(id),
    constraint client_id_fk foreign key (client_id) references clients(id),
	constraint table_id_fk foreign key (table_id) references tables(id)
	);


insert into table_assigment(client_id, table_id, in_time, out_time) VALUES
	(1, 2, '2023-09-23 20:00:00', '2023-09-23 21:00:00'),
	(2, 4, '2023-09-23 21:00:00', null),
	(3, 2, '2023-09-23 21:00:00', null),
	(4, 1, '2023-09-23 22:00:00', null);

create table orders (
	id serial,
	table_assigment_id int,
	order_time timestamp,
	pizzas integer[],
	constraint table_assigment_id_fk foreign key (table_assigment_id) references table_assigment(id)
);

insert into orders (table_assigment_id, order_time, pizzas) VALUES
	(1, '2023-09-23 20:05:00', '{1,3,2}'),
	(3, '2023-09-23 21:04:00', '{1,1,1,1}'),
	(2, '2023-09-23 21:05:00', '{2,3,4,1,1,4}'),
	(2, '2023-09-23 21:07:00', '{1,1}'),
	(2, '2023-09-23 20:10:00', '{3}');

