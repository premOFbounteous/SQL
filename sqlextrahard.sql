create database ecommercesystem;
use ecommercesystem;

create table if not exists users (
  userid int primary key auto_increment,
  name varchar(100),
  email varchar(100),
  role enum('admin','vendor','customer')
);

create table if not exists vendors (
  vendorid int primary key auto_increment,
  userid int,
  companyname varchar(100),
  rating decimal(3,2),
  foreign key (userid) references users(userid)
);


create table if not exists products (
  productid int primary key auto_increment,
  vendorid int,
  name varchar(100),
  price decimal(10,2),
  stockqty int,
  category varchar(50),
  foreign key (vendorid) references vendors(vendorid)
);


create table if not exists orders (
  orderid int primary key auto_increment,
  customerid int,
  orderdate date,
  status enum('pending','processing','shipped','delivered','cancelled'),
  foreign key (customerid) references users(userid)
);


create table if not exists orderitems (
  orderitemid int primary key auto_increment,
  orderid int,
  productid int,
  quantity int,
  itemprice decimal(10,2),
  foreign key (orderid) references orders(orderid),
  foreign key (productid) references products(productid)
);


create table if not exists payments (
  paymentid int primary key auto_increment,
  orderid int,
  amount decimal(10,2),
  method enum('cash','card','upi','netbanking'),
  status enum('pending','completed','failed'),
  foreign key (orderid) references orders(orderid)
);


create table if not exists reviews (
  reviewid int primary key auto_increment,
  productid int,
  customerid int,
  rating int,
  comment text,
  reviewdate date,
  foreign key (productid) references products(productid),
  foreign key (customerid) references users(userid)
);


create table if not exists commissions (
  commissionid int primary key auto_increment,
  vendorid int,
  month date,
  totalsales decimal(10,2),
  commissionamount decimal(10,2),
  foreign key (vendorid) references vendors(vendorid)
);


create table if not exists auditlog (
  logid int primary key auto_increment,
  userid int,
  action varchar(100),
  tableaffected varchar(50),
  timestamp datetime,
  foreign key (userid) references users(userid)
);



delimiter //

create procedure placeorder(
    in p_customerid int,
    in p_productid int,
    in p_quantity int
)
begin
    declare v_stock int;
    declare v_price decimal(10,2);
    declare v_orderid int;

    start transaction;

    -- 1. check stock
    select stockqty, price into v_stock, v_price
    from products
    where productid = p_productid
    for update;

    if v_stock < p_quantity then
        rollback;
        select '❌ insufficient stock, transaction rolled back' as message;
    else
        -- 2. insert into orders
        insert into orders(customerid, orderdate, status)
        values(p_customerid, curdate(), 'pending');

        set v_orderid = last_insert_id();

        -- 3. insert into orderitems
        insert into orderitems(orderid, productid, quantity, itemprice)
        values(v_orderid, p_productid, p_quantity, p_quantity * v_price);

        -- 4. update product stock
        update products
        set stockqty = stockqty - p_quantity
        where productid = p_productid;

        -- 5. logging
        insert into auditlog(userid, action, tableaffected, timestamp)
        values(p_customerid, 'placed order', 'orders/orderitems', now());

        commit;
        select concat('✅ order placed successfully, orderid=', v_orderid) as message;
    end if;
end//

delimiter ;


delimiter //

create procedure calculatecommission(
    in p_vendorid int,
    in p_month date
)
begin
    declare v_totalsales decimal(10,2);

    -- calculate total sales for the vendor in given month
    select ifnull(sum(oi.itemprice),0.00) into v_totalsales
    from orderitems oi
    join products p on p.productid = oi.productid
    join orders o on o.orderid = oi.orderid
    where p.vendorid = p_vendorid
      and date_format(o.orderdate,'%Y-%m') = date_format(p_month,'%Y-%m');

    -- insert commission (10% of total sales)
    insert into commissions(vendorid, month, totalsales, commissionamount)
    values(p_vendorid, p_month, v_totalsales, v_totalsales * 0.10);

    select concat('✅ commission calculated: ', v_totalsales * 0.10) as message;
end//

delimiter ;

delimiter //

create procedure addreview(
    in p_customerid int,
    in p_productid int,
    in p_rating int,
    in p_comment text
)
begin
    declare v_count int;

    start transaction;

    -- 1. check if customer purchased the product
    select count(*) into v_count
    from orders o
    join orderitems oi on o.orderid = oi.orderid
    where o.customerid = p_customerid
      and oi.productid = p_productid
    for update;

    if v_count = 0 then
        rollback;
        select '❌ customer has not purchased this product, transaction rolled back' as message;
    else
        -- 2. insert into reviews
        insert into reviews(productid, customerid, rating, comment, reviewdate)
        values(p_productid, p_customerid, p_rating, p_comment, curdate());

        commit;
        select '✅ review added successfully' as message;
    end if;
end//

delimiter ;


delimiter //

create trigger trg_orderitems_insert
before insert on orderitems
for each row
begin
    declare v_stock int;

    select stockqty into v_stock
    from products
    where productid = new.productid
    for update;

    if v_stock < new.quantity then
        signal sqlstate '45000'
        set message_text = '❌ insufficient stock, cannot insert orderitem';
    else
        update products
        set stockqty = stockqty - new.quantity
        where productid = new.productid;
    end if;
end//

delimiter ;


delimiter //

create trigger trg_products_update
after update on products
for each row
begin
    declare v_role varchar(20);

    select role into v_role from users where userid = new.vendorid;

    if v_role in ('vendor','admin') then
        insert into auditlog(userid, action, tableaffected, timestamp)
        values(new.vendorid, 'updated product', 'products', now());
    end if;
end//

delimiter ;


delimiter //

create trigger trg_reviews_insert
after insert on reviews
for each row
begin
    update products p
    set p.rating = (
        select avg(r.rating)
        from reviews r
        where r.productid = new.productid
    )
    where p.productid = new.productid;
end//

delimiter ;


delimiter //

create procedure placeorder_with_payment(
    in p_customerid int,
    in p_productid int,
    in p_quantity int,
    in p_paymentamount decimal(10,2),
    in p_paymentmethod varchar(50)
)
begin
    declare v_stock int;
    declare v_price decimal(10,2);
    declare v_orderid int;

    start transaction;

    -- check stock
    select stockqty, price into v_stock, v_price
    from products
    where productid = p_productid
    for update;

    if v_stock < p_quantity then
        rollback;
        select '❌ insufficient stock, transaction rolled back' as message;
    else
        -- insert order
        insert into orders(customerid, orderdate, status)
        values(p_customerid, curdate(), 'pending');

        set v_orderid = last_insert_id();

        -- insert orderitem
        insert into orderitems(orderid, productid, quantity, itemprice)
        values(v_orderid, p_productid, p_quantity, p_quantity * v_price);

        -- deduct stock
        update products
        set stockqty = stockqty - p_quantity
        where productid = p_productid;

        -- insert payment
        if p_paymentamount < v_price * p_quantity then
            rollback;
            select '❌ payment insufficient, transaction rolled back' as message;
        else
            insert into payments(orderid, amount, method, status)
            values(v_orderid, p_paymentamount, p_paymentmethod, 'Paid');
        end if;

        commit;
        select concat('✅ order and payment successful, orderid=', v_orderid) as message;
    end if;
end//

delimiter ;


delimiter //

create procedure calculatecommission_transaction(
    in p_month date
)
begin
    declare v_vendorid int;
    declare v_totalsales decimal(10,2);

    -- cursor and handler declarations first
    declare done int default 0;
    declare vendor_cursor cursor for 
        select vendorid from products group by vendorid;
    declare continue handler for not found set done = 1;

    start transaction;

    open vendor_cursor;

    vendor_loop: loop
        fetch vendor_cursor into v_vendorid;
        if done = 1 then
            leave vendor_loop;
        end if;

        -- calculate total sales
        select ifnull(sum(oi.itemprice),0.00) into v_totalsales
        from orderitems oi
        join products p on p.productid = oi.productid
        join orders o on o.orderid = oi.orderid
        where p.vendorid = v_vendorid
          and date_format(o.orderdate,'%Y-%m') = date_format(p_month,'%Y-%m');

        -- insert commission
        insert into commissions(vendorid, month, totalsales, commissionamount)
        values(v_vendorid, p_month, v_totalsales, v_totalsales * 0.10)
        on duplicate key update 
            totalsales = values(totalsales), 
            commissionamount = values(commissionamount);
    end loop;

    close vendor_cursor;
    commit;

    select concat('✅ commissions calculated for month ', date_format(p_month,'%Y-%m')) as message;
end//

delimiter ;

insert into users (userid, name, email, role) values
(1, 'Ananya', 'ananya@mail.com', 'Customer'),
(2, 'Ravi', 'ravi@mail.com', 'Customer'),
(3, 'Meena', 'meena@mail.com', 'Customer'),
(4, 'VendorUser1', 'vendor1@mail.com', 'Vendor'),
(5, 'VendorUser2', 'vendor2@mail.com', 'Vendor'),
(6, 'AdminUser', 'admin@mail.com', 'Admin');


insert into vendors (vendorid, userid, companyname, rating) values
(1, 4, 'TechWorld', 4.5),
(2, 5, 'HomeStore', 4.2);


insert into products (productid, vendorid, name, price, stockqty, category) values
(1, 1, 'Laptop', 50000, 20, 'Electronics'),
(2, 1, 'Headphones', 2000, 100, 'Electronics'),
(3, 2, 'Sofa', 15000, 10, 'Furniture'),
(4, 2, 'Dining Table', 12000, 5, 'Furniture'),
(5, 1, 'Keyboard', 1500, 50, 'Electronics');


insert into orders (orderid, customerid, orderdate, status) values
(1, 1, '2025-08-01', 'Completed'),
(2, 2, '2025-08-05', 'Completed'),
(3, 1, '2025-09-01', 'Completed'),
(4, 3, '2025-09-03', 'Pending');


insert into orderitems (orderitemid, orderid, productid, quantity, itemprice) values
(1, 1, 1, 1, 50000),   -- Laptop
(2, 1, 2, 2, 4000),    -- Headphones
(3, 2, 3, 1, 15000),   -- Sofa
(4, 3, 5, 3, 4500),    -- Keyboards
(5, 3, 2, 1, 2000),    -- Headphones
(6, 4, 4, 1, 12000);   -- Dining Table


insert into payments (paymentid, orderid, amount, method, status) values
(1, 1, 54000, 'UPI', 'Paid'),
(2, 2, 15000, 'Card', 'Paid'),
(3, 3, 6500, 'UPI', 'Paid'),
(4, 4, 12000, 'Cash', 'Pending');


insert into reviews (reviewid, productid, customerid, rating, comment, reviewdate) values
(1, 1, 1, 5, 'Great laptop!', '2025-08-02'),
(2, 2, 1, 4, 'Good headphones', '2025-08-02'),
(3, 3, 2, 5, 'Very comfortable sofa', '2025-08-06'),
(4, 5, 1, 3, 'Decent keyboard', '2025-09-02'),
(5, 4, 3, 4, 'Nice dining table', '2025-09-04');


select p.productid, p.name, sum(oi.quantity) as total_sold
from orderitems oi
join products p on oi.productid = p.productid
group by p.productid, p.name
order by total_sold desc
limit 5;

select v.vendorid, v.companyname,
       date_format(o.orderdate, '%Y-%m') as month,
       sum(oi.itemprice) as total_sales,
       sum(oi.itemprice) * 0.10 as commission
from vendors v
join products p on v.vendorid = p.vendorid
join orderitems oi on p.productid = oi.productid
join orders o on oi.orderid = o.orderid
group by v.vendorid, v.companyname, date_format(o.orderdate, '%Y-%m')
order by month desc, total_sales desc;

select u.userid, u.name,
       count(distinct o.orderid) as total_orders,
       sum(oi.itemprice) as total_spent
from users u
join orders o on u.userid = o.customerid
join orderitems oi on o.orderid = oi.orderid
group by u.userid, u.name
order by total_orders desc, total_spent desc
limit 5;


-- per product
select p.productid, p.name,
       round(avg(r.rating),2) as avg_rating, count(r.reviewid) as total_reviews
from products p
left join reviews r on p.productid = r.productid
group by p.productid, p.name
order by avg_rating desc;

-- per vendor
select v.vendorid, v.companyname,
       round(avg(r.rating),2) as avg_rating
from vendors v
join products p on v.vendorid = p.vendorid
join reviews r on p.productid = r.productid
group by v.vendorid, v.companyname
order by avg_rating desc;



