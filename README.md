# VFPTransactions

VFPTransactions is adding the feature of a **transaction log** to any DBC database in Microsoft Visual FoxPro 9. It is based on insert/update/delete triggers, which in VFP are reliably happening for every single record - no matter if you manually edit data in a Browse window or cause them for thousands of records -one after another - by an SQL UPDATE statement, for example. This way the log can't be circumvented unless you modify the trigger expressions calling into the stored procedures. Which makes it an ideal evnt and trigger for maintaining a transaction log.

To get starting the only requirement is your DBC is VFP9 compatible, which means it will support the execution of VFP9 language in stored procedures added that make use of the VFP9 feature of scattering a record to an object and inserting from an object.

The very basic principle of VFPTransactions is hooking into whatever currently is already established as stored procedures and triggers in a DBC. Establishing a Transactionlog is as easy as calling a script while the DBC is open exclusive. VFP Transactionlog procedures will be appended to any existing procedures and triggers calls will be modified, if already existing from referential integrity triggers, for example, to make a call into the VFPlog stored procedure, which is the starting point of persisting changes into a transaction log.

The working principle is establishing a queue that takes in log info objects including the data modified (as record objects - the already mentioned VFP9 feature I'm exhaustively using) and a timer processing that queue. Initial to queueing some head metadata is stored, but more on the details later. Besides the queue and timer establishing the actual logging part, the last ingredient requires your intention, when you actually already make use of VFPs transaction capabilities. And you likely do, if you're interested in having a transaction log in your DBC.

As should be known VFP transactions are actually not logged and the feature they offer is a reliable commit or rollback of all operations done within a transaction. The few transaction-related commands in VFP are quite self-explanatory BEGIN TRANSACTION begins a manual transaction, END TRANSACTION commits it, ROLLBACK rolls back changes made in a transaction and TXNLevel() is a function returning the current transaction level of the current datasession. Transactions can't be named, but TxnLevel() already hints on the ability to nest several transactions. The effect of transactions is rigorous locks on all DBFs involved in a transaction, which lock out any other user trying to do something with the same tables that are already involved in the transaction of another user, so the best practice is to keep them as short as possible. When you buffer all changes of a user in tables and finally have a save routine that commits the buffers that's the moment to start a transaction as best practice, store all buffers of tables involved - for example, an order and all its order details - to then commit the flushed buffers by ending the transaction or rolling back all changes when something fails. So far just a very brief description on how to make use of transactions in VFP.

The technical part of it is that you only need to change your ways in a very slight but subtle difference from directly using BEGIN TRANSACTION, END TRANSACTION, and ROLLBACK and use the methods VFPTransactions provides in the form of methods of a \_VFP.Transactions object, that is established for transaction logging.

## Usage / Getting Started with VFPTransactions

Before you go into any detail you can test VFPTransactions on a sampledatabase coming with it that does a minimal test of the overall system and documents the steps of getting started. Open the porject (confirm the new home directory, obviously) and start sampleusage.prg, then you're in the middle of using the system.

## Preparing your codebase for the usage of VFP   Transactions

Going through all thatÄs done in that sampleusage.prg, obviously the first step is to add the VFPTransactions stored procedures to your DBC and set all insert/update/delete triggers to call into them. That's taken care of with a simple call of createorupdatetransactionlog.prg:
```
Do create_or_alter_vfptransactions_storedprocedures WITH "c:\path\to\yourdatabase.dbc"
```
or when you prefer and CD into the PRGS directory or add it to SET PATH and/or SET PROCEDURE:
```
create_or_alter_vfptransactions_storedprocedures("c:\path\to\yourdatabase.dbc")
```
The sampleusage.prg does this stel in line 42 after first copying a sampledata.dbc, that in itself has no data yet but is already prepared with VFPS referential integrity stored procs and triggers in several tables calling them. The code in create_or_alter_vfptransactions_storedprocedures takes the given DBC, adds VFPTransactions Procedures from vfptransactions_storedprocedures.prg and then alters the insert/update/delete trigger calls from referntial integrity or adds its own calls in as first and only call. I fear VFP referential integrity generator will not be as cooperative when you change rules and let it rgenerate procedures, it'll simply overwrite the trigger calls in the table properties, but no problem, VFPTransactions can add itself back when you call it after every new update of VFP referential integrity. It's just demonstrating the compatibility with whatever triggers you have in your database anyway.

Congratulations, you're almost there already. To let VFPTransactions know of your transactions also make the following replacements in your code:
```
BEGIN TRANSACTION must be replaced by _vfp.Transactions.Begin(Set('DataSession'))
END TRANSACION must be replaced by _vfp.Transactions.End(Set('DataSession'))
ROLLBACK must be replaced by _vfp.Transactions.Rollback(Set('DataSession'))
```
This can be done 1:1 at any place without putting any deeper thought to it. Even if your framework makes use of these VFP commands in objects managing transactions this way itself, VFPTransactions will just add a further layer to this and take over making the actual VFP command calls to really begin, end/commit or rollback transactions. And I really mean, don't begin questioning this. Everrything in that has it's reasoning also the parameter Set("Datasession"). It can't be done within the Begin(), End(). and Rollback() methods, as the TransactionLogManager lives in its own datasession. Only the caller can pass in from which datasessionId the call comes from and for which datasession, therefore, the transaction should begin, end or rollback. To explain why would need a few lessons on how datasessions are switched when VFP siwtches context between objects, not only to forms with a private datasession or session objects.

One advantage of the way VFPTrmnsactions manages transactions is that objects will be created and stored in a collection within the VFPTransaction object world, that when destroyed for any reason - also system crashes - end with ROLLBACK by default. So any unplanned exit puts data back into the previously known valid state (as long as the crash isn't really something very disruptive like a power outage without a UPS).

Doing transactions this way you inform the TranactionLogManager to do a final commit on some transaction into the log so the queued data about this transaction doesn't linger in memory longer than the actual transaction. Which also tells why this is definitely not just an optional change. It's one of the major ingredients making VFPTransactions a possible transaction log mechanism - by knowing about your manual transactions. There are no native events happening that are triggered by starting or ending transactions and this is the most unobtrusive way of letting a transaction logger know about your transactions. It's not asking for much.

Just a side note on the thought work flowing into this: In the initialization phase VFPTransactions establishes object for all current data sessions and their transaction level, but will not interfere in any of them. When a transaction level of any datasession already is >0, then some other code has established that connection. VFPTransaction notices this transaction but will neither end it or roll it back. It will still commit changes found to be done within such transactions to the log.

### Establish the transaction log as the first thing in your application code

The only other change in your project will be establishing the main \_vfp.Transactions object that's obviously a prerequisite of making these calls. Well, or do nothing. The good news is that the stored procedure added to the insert/update/delete triggers of your DBC tables doesn't rely on \_VFP.Transactions being established beforehand, the first trigger queueing the first record of the first table involved in any modification by SQL or XBase code (APPEND/REPLACE) will also establish \_VFP.Transactions. It's still recommended that you take it into your hands to do so, which also is a very simple single line of code in your main.prg:

```
Open Database ("c:\path\to\yourdatabase.dbc") && which includes the stored procedures of VFPTransactionlog
Set Database To yourdatabase
dbcCreateObject("TransactionLogManager")
```
And then watch it work. By default, this will establish a subdirectory yourdatabaseLog where all log related data will be created. The structure of which is described in the documentation of the project.

And now? Do you need to change your codebase to do anything in transactions so they are getting attention from the TransactionLogManager? Yes, as said above when you make use of manual transactions by now, the three native commands need to be redirected to VFPTransaction methods. But VFPTransactions actually also works without establishing transactions in your project, because it also auto commits changes by a timer, it has to manage any changes of DBC tables not happening in a transaction, too, and does so by also establishing management objects for transaction-level 0. it's only missing anything you do in tables not covered by triggers of a DBC, but that's just obviously leaving the scope of the Transaction log covering all tables of a DBC.

Everything about VFPTransactions is contained within the stored procedures, so there is no way of stepping on your own foot by unloading any class libraries from memory. The destroy events of all involved classes are doing their best to gracefully exit all transactions and put the transaction log in a healthy state. VFPTrnansactions therefore also hooks into the ON SHUTDOWN event. Whatever you want to do there, establish your ON SHUTDOWN first, for example ON SHUTDOWN QUIT or ON SHUTDOWN DO tidyup() and the initialization of the TransactionLogManager will override this with its own release call, but within that release will finally change back to what you defined beforehand.

This also means there is no reason to include any finishing call to \_vfp.Transactions in your tidy up code. If you want to close the database and fear \_vfp.Transactions to fail in such cases, you can finish it anyway by calling
```
_vfp.Transactions.Release()
```

But you can obviously also make this call at any time you want to pause transactions and do some bulk operations not logged. Then reestablish it by dbcCreateObject("TransactionLogManager").

It can take a while for \_vfp.Transactions to release as it also closes all transactions and finishes committing any data to DBC tables and the log. That's already all to know about using VFPTransactions.

## Some highlights

Some highlights to mention at this stage are how this all works despite the fact VFP is not a server. But before I go into the consequences of that, let me first state that VFPTransactions is mainly a full log of what happens in your DBC, not only when it happens in transactions. It's just typically called transaction log in other databases, as everything happens within transactions in database servers, if not manual then automatic transactions. VFP is kind of that way too, anything not happening within a manual transaction of course also is stored in the DBFs of a DBC, its just happening at transaction level 0, more directly. It only may get lagged off by using VFP's buffer mechanism, which actually works well together with transactions, too. But to stress it out once more: You get the log of all changes, as events of data changes are the insert/update/delete triggers fired by a DBC. They also happen outside of any transaction.

Coming back to the aspect of VFP not being a database server: Stored procedures, like everything else, are running in client-side processes. The downside of this is: Don't expect a simple log of a sequence of records in one place. Log data is split into a hierarchical structure of directories, which include client computer names to have separate log locations for all clients using a DBC, even split by more unique identifiers like the user account name and process id, for the case several applications use the same DBC on the same client by the same windows user, too.

Also, VFP transactions are not just nested, there are nested transactions happening in parallel for any datasession you may use by forms with private datasession, too. So you can have nested and parallel transactions, not only because clients run in parallel, but also in a single application session multiple forms can run transactions in parallel at different stages of each object like a form having its own separate private datasession.

VFPTransactions does use one simple sequence of logids that's created by VFPs fine autoninc integer type maintained in a logid.dbf which never keeps any records. Only the dbf header is used, where the next value of such a counter is stored by VFP. Safe from any transactions, by the way. So no LogId is given twice, not even in separated clients.

The directory structure will have one transactionlog.dbc for all transactions in all times the DBC is used while VFPTransactions is established. There is a sessions subdirectory which will host further subdirectories per datasession and within these, you'll find directories per transaction, also for the non-transactional level 0. You can actually find all data related to some transactions in these end levels. More on that structure in the next section. 

But before I get into explaining what you find in which files the last highlight to mention here, is, that VFPTransactions both participates and not participates in running transactions in different log tables and thus in one case experiences in the other case does not experience the case of a rollback, so you find files that only persisted data which also is persisted in the DBC tables participating in the transactions, but you can also find what happened in the transactions even though it was rolled back in the original tables. So this could even be used to recover things users may think are lost as they canceled something instead of saving it. As soon as a DBF's triggers are triggered, this will get into the log and stay there. And that happens even in buffered mode. The only exception made by design is that the previous trigger is called first and its return value is respected. If a trigger returns .F. it means VFPs database engine will not execute the triggered change. VFPs own referential integrity stored procedures make use of this feature for example. And when a record does not adhere to RI rules, for example does not have a valid foreign key, a record is rejected. So using this or other variants of procedures returning .F. will also cause VFPTransactions to not log them as if their insert/update/delete was never requested at all.

An observation I made in testing it, though everything is queued in chronological order and gets a LogId in chronological order, the log dbfs can easily have records stored out of order by LogId. An index on this id is established to easily get rows in log id order. There are good reasons for this in the distributed nature of transactions. For example, the transaction level 0 is discovered very early by the initialization of VFPTransactions, but this discovery is only queued and only later inserted into log dbfs when a timer commits queued data. What regularly happens is, that any trigger coming from a DBF stores head data about itself, the effected table and record number into meta head data about this trigger, and only after that, the VFPTransactions system is establishing a record about the transaction start. It's nothing to worry about. Surely not a highlight to be happy about, but it's not a sign of malfunction. If you follow a coverage log of the work done by VFPTransacations it all becomes a bit more logical, why things happen in the order they do. It's nevertheless very well worth noting that this also is a reason there is no foreign key constraint on the transactionLogId of all records part of that transaction, as the first records might get into log dbfs before the initializing record of a transaction, not only when the transaction isn't actually managed by a Transactionmanager class, as it is transaction level 0 or was already started by something else. What is reliable though is that alltransactionsevents.dbf contains a record about the initialisation of VFPTransactions for an application session a first (cLogType = 'I' as init - we'll get to what this means later) and a similar entry for the release of VFPTransactions as last record (cLogType= = 'R')'. These records are logged directly, not first queued. There surely is a bit room for improvement of scuh things, but I want to publish this as v1.0 now as it's very ripe for becoming public.

## The transaction log

I won't go into all details of what the transaction log data is and means, just a few pointers here where to find the most important data about the log.

### 1. directory level \yourdbcLog\

1. Within a new subfolder of your DBC called yourdbcLog you find a transactionlog.dbc, which is the database container of all the DBFs within the same folder. VFPTransactionlogs creates a very detailed substructure about what happened, but on this level you will actually see all the root data of all events, which mainly are the triggers causeing VFPTransactions to log them but also some internal events, the initialisation and release, creating or discovering running datasessions and transactionlevels. The types of events have a single letter in a cLogType field:
I - Init
s - session discovered (iSessionId, iTransactionlevel tell the main identifiers about it)
t - transaction discovered or started (again iSessionId, iTransactionlevel identifies which one). 
    Here the iLogId also becomes the itransactionlogid of all events and meta data records that happen within the transaction
T - triggers. These are the usual entry points, if a log entry is not initiated from you calling the \_vfp.Transactions.Begin() method.
    And this should also explain to you where "discovered" sessions and transactions come from. A trigger tells VFPTransaction in which datasessionid
    and transaction level it happens. Then VFPTransactions does not know this combination by now this is causing cLogType = "s" and "t" entries.
R - Release
This field and other info is found in multiple tables, but mainly in alltransactionevents.dbf

You will find this data repeated and split into relevant types. Tables with your databasename as prefix will only contain cLogType = 'T' events, the triggers, so just the main actors in contributing the data to the log. For any session/transaction a trigger happens in a specific table is generated. This does not mean every single transaction will cause a table here, for example YOURDATAtriggerevents_s1_t1 will contain all trigger events coming from the default datasesion 1 and in a transaction level 1, whcih could be a majority of all events, when you don't use forms with private datasession. The Sessions and Tranasactions tables will jsut contain the cLogType='s' and cLogType='t' events.

You find repeats and more and more specialised filtered parts of the data in the sessions subfolders, so lets go stright to the end leaves of this, where you find the data that will likely interest you much more than all the meta data.

### 2. directory level \yourdbcLog\sessions

On this level no concrete dbc and dbf is created, but every datasession will have a directory in here, which is dscribed in the next section. Just note this directory keeps the clutter of names from the root transactionlog.dbc directory, all details are in the one \sessions\ directory.

### 3. directory level \yourdbcLog\sessions\logid\_N\_sM\_computername\_winaccountname\_processid

Evreything in the log gets a logid, and the events that cause such an organsiational folder to be created also get an id and put it into the directory nmame. The directores of sessions thereby sort by their name and the N in logid\_N\_sM\_computername\_winaccountname\_processid os the log id. The part \_sM\_ stands for session and M is the session id - Set("Datasession"). The rest is to have a unique name. Since VFP is not a server this creates directories per process of a specific user on a specific client. Which also means no two clients clash in concurrent file access of log files other than in the root and sessions folder. But surely not in the more important details in the next lebel described in the 4th directory level section.

Within these specific session folders you'll find a sessionlog.dbc and Sessions and Transactions dbfs about the log infos of cLogType='s' and 't', not that interesting, but still just filtered for a single session id, so anything that happens in a certain session number. 

### 4. directory level \yourdbcLog\sessions\logid\_N\_sM\_computername\_winaccountname\_processid\logid\_3\_s1\_t0

\logid\_3\_s1\_t0 are a little easier to decode with everythign you already know. Obvisouly this is just shortly noting the logid of the single transaction stored in such a folder and the sesion id and transaction level in which it happens. But the data within is foinally getting down to the core data loged, the data coming from your DBFs.

Ever folder in thes level has a logdetails.dbc, which seems overkill but makes each folder independently movable for purposes like replication of data. All data is obviously indirectly connected by the logid you find in most log tables, but any folder is self contained with it's own dbc (if there is one) and dbfs. Here the Sessions. and Transactions tbles each should only have 1 record that is the session/transaction level, again, so the major players in this directory are the DBFs named after your tables. The table with Meta suffix contains the same type of data I already described, but the other table will have the same table structure as your original tables. This is where the data is logged.

So here you find all the records that where modified in the single transaction. Besides that, you find the Meta data to refer to some things that can't actually be persisted within the record itself, the DELETED() status and the recno the record had at log time. The ecno especially is negative for buffered records, as they actuylla are not yet stored in a dbf, but their insert/update and even their delete cause table triggers and so this logging. So even before thy get flushed from the buffer into the DBF files they become saved here and even if they are deleted and reverted this reflects here. The TABLEUPDATE() comand, which commits the bufer to the DBF almost like a transaction comit will not cause another trigger, so it becomes more important to give your tables a primary key Id column that identifies which record actually was logged.

The obvious last question will be about the composition of the dbf names, so let's look at one in detail -  For example: ORDERScrc933918722.dbf
Well, obviously thats an ORDERS.DBF copy, but what about the crc933918722 part. Well, if such tables are generated and would on higher level directories also aggregate data of multiple transactions up to the full history of all recrods, this will only work as long as tables don't change their structure and you never add a field or change a field size. VFPTranasactions reflects this with a crc checksum of the datatypes and other information taken from an AFIELDS array. If your table structure changes but the name stays, you still will have a separate name here.

So this was a roundtrip through the files in the transaction log subdirectory structure. Fell free to modify the DataLogger class to your needs and maybe simplify this srtructure. My goal was to actually be able to have separate files per single transaction and still some head info on a root level. That's obvioulsy achieved.

## The code

Last not least, I hope you find this a useful addition of a DBC. It's now also up to you how you extend this. All essential code for the logging is found in the vfptransactions_storedprocedures.prg. This has a good portion of comments describing how it works. Let me just poiint out the major architecture as already described in the first section of thie readme.md about the VFPTransactions in general.

### TransactionLogManager and the manager hiewrarchy

The class that is bringing up all the infrastructure besides itself is the TransactionLogManager. It's always the root object for any firther substrcuture. The TransactionLogManager is inheriting from SessionManager, as the Sessionmanager is the closest similar class to it, the TransactionLogmanager just has the additional initialisation part and orchestrates other objects around it. The TransactionLogmanager keeps track of a Sessionmanagers, of which each one is responsible for one datasession. The sessionmanagers in turn manage a list of Transactionmanagers, which are actually the instances encapsulating the VFP transaction commands in their init and destroy. Besdies that, the Sessionmanagers each have their own Sessionlogger handling the data logging itself and the Transationmanagers start a TransactionLogger for that matter. The loggers and managers all inherit from a base class DataLogger that is the foundation of all logging done.

Obviously the Queue and Timer have a special meaning as single instances surrounding thes hierarchy of managers. The last part are just two procedureal stored procvedures, which the triggers of the database tables will call, one creating a log object as first step of the logging, the other being called with that object and the result of the trigger call that previsouly was set, for eample as here by VFP referential integrity. 

### LogRecord()

The LogRecord procedure is the inner call that creates a log object, which besides a record object of the table fields hasmeta data like LigId, recno, deleted staus, time of the log, datasession and transactionlevel. This is mainly just created as first, to avoid some overriding by the previous triggger code. 

### VFPLog()

This is the outer function called by the trigger and besides respecting the .F./.T. decision referential integrity code does, for example, it just puts the log info on a queue and returns back to the application code. In a DBC with no trigger code before establishing VFPTransactions, you get a call that merely takes in the logobject result and then puts it on the TransactionLogQueue.

### Log Queue and Timer

The Queue and Timer are somewhat the real root instead of the TransactionLogManager, but indeed the TransAtionLogmanager creates them with itself and his managers hierarchy. The Queue is feed by the trigger procedures and the Timer then is the final puzzle piece, that takes care for processing the ququed log info objects. The timer has a quite short interval, but it'll only stay active as long as the queue count is >0. It'll try to process as many log items as it can and then actually sleep when count becomes 0. The timer events disables the timer to avoid being triggered before it finishes on one side, but on the other side the timer will not need to be kept "alive" when the triggers are thre to activate the timer again when something new arrives in the queue, so that is used to keep the timer as inactive as it can to not steal process time from the rest of the application.
