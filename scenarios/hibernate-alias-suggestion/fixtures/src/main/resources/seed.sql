-- Run by H2 itself on connect (INIT=RUNSCRIPT), so the seed emits no JDBC span.
CREATE TABLE IF NOT EXISTS author (id INT PRIMARY KEY, name VARCHAR(64));
CREATE TABLE IF NOT EXISTS book (id INT PRIMARY KEY, title VARCHAR(64), author_id INT REFERENCES author(id));
MERGE INTO author KEY (id) VALUES (1,'a1'),(2,'a2'),(3,'a3'),(4,'a4'),(5,'a5'),(6,'a6');
MERGE INTO book KEY (id) VALUES (1,'b1',1),(2,'b2',2),(3,'b3',3),(4,'b4',4),(5,'b5',5),(6,'b6',6);
