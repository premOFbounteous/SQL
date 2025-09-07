create database medicalsystem;
use medicalsystem;

create table if not exists patients(
  patientid int primary key auto_increment,
  name varchar(100),
  dob date,
  gender enum('male','female','other'),
  contactinfo varchar(255)
);


create table if not exists doctors(
  doctorid int primary key auto_increment,
  name varchar(100),
  specialty varchar(100),
  availableslots int
);


create table if not exists appointments(
  appointmentid int primary key auto_increment,
  patientid int,
  doctorid int,
  appointmentdate date,
  status enum('pending','booked','unavailable'),
  foreign key (patientid) references patients(patientid),
  foreign key (doctorid) references doctors(doctorid)
);


create table if not exists treatments(
  treatmentid int primary key auto_increment,
  appointmentid int,
  treatmenttype varchar(100),
  cost decimal(10,2),
  notes text,
  foreign key (appointmentid) references appointments(appointmentid)
);


create table if not exists billing(
  billid int primary key auto_increment,
  patientid int,
  totalamount decimal(10,2),
  paymentstatus enum('pending','paid','partially paid','cancelled'),
  foreign key (patientid) references patients(patientid)
);


delimiter //
create procedure bookappointment(
  in p_patientid int,
  in p_doctorid int,
  in p_date date
)
begin
  declare slots int;

  select availableslots into slots
  from doctors
  where doctorid = p_doctorid;

  if slots > 0 then
    insert into appointments(patientid,doctorid,appointmentdate,status)
    values(p_patientid,p_doctorid,p_date,'booked');
  else
    insert into appointments(patientid,doctorid,appointmentdate,status)
    values(p_patientid,p_doctorid,p_date,'unavailable');
  end if;
end//
delimiter ;


delimiter //
create procedure generatebill(
  in p_patientid int
)
begin
  declare total decimal(10,2);

  select ifnull(sum(t.cost),0.00) into total
  from treatments t
  join appointments a on a.appointmentid = t.appointmentid
  where a.patientid = p_patientid;

  insert into billing(patientid,totalamount,paymentstatus)
  values(p_patientid,total,'pending');
end//
delimiter ;


delimiter //
create trigger trg_after_appointment
after insert on appointments
for each row
begin
  if new.status = 'booked' then
    update doctors
    set availableslots = availableslots - 1
    where doctorid = new.doctorid;
  end if;
end//
delimiter ;


delimiter //
create trigger trg_after_treatment
after insert on treatments
for each row
begin
  declare pid int;
  declare total decimal(10,2);

  select patientid into pid
  from appointments
  where appointmentid = new.appointmentid;

  select ifnull(sum(t.cost),0.00) into total
  from treatments t
  join appointments a on a.appointmentid = t.appointmentid
  where a.patientid = pid;

  insert into billing(patientid,totalamount,paymentstatus)
  values(pid,total,'pending')
  on duplicate key update totalamount = total;
end//
delimiter ;

-- doctors
insert into doctors(name,specialty,availableslots) values
('dr. sharma','general',2),
('dr. mehta','orthopedics',1),
('dr. singh','dentist',3);

-- patients
insert into patients(name,dob,gender,contactinfo) values
('ananya','1995-05-10','female','9999999999'),
('ravi','1990-01-20','male','8888888888'),
('tina','2000-03-15','female','7777777777');

-- appointments
call bookappointment(1,1,'2025-09-06');  
call bookappointment(2,2,'2025-09-07');  
call bookappointment(3,3,'2025-09-08');  
call bookappointment(2,1,'2025-09-09');  


insert into treatments(appointmentid,treatmenttype,cost,notes) values
(1,'consultation',500.00,'first visit'),
(2,'physiotherapy',800.00,'back pain'),
(3,'dental cleaning',300.00,'routine checkup');


call generatebill(1); 
call generatebill(2);  
call generatebill(3);  


select a.appointmentid,a.appointmentdate,a.status,
       p.name as patient,d.name as doctor,d.specialty
from appointments a
join patients p on p.patientid=a.patientid
join doctors d on d.doctorid=a.doctorid;


select p.patientid,p.name,ifnull(b.totalamount,0.00) as total,b.paymentstatus
from patients p
left join billing b on b.patientid=p.patientid;


select d.name as doctor,t.treatmentid,t.treatmenttype,t.cost,a.appointmentdate,p.name as patient
from treatments t
join appointments a on a.appointmentid=t.appointmentid
join doctors d on d.doctorid=a.doctorid
join patients p on p.patientid=a.patientid
where d.doctorid=1;
