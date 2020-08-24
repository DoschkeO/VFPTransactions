# VFPTransactions

VFPTransactions is adding the feature of a **Transactionlog** to any DBC database in Microsoft Visual FoxPro 9. It is based on insert/update/delete triggers, which in VFP are reliably happening for every single record - no mattter if you manually edit data in a Browse window or cause them for thousands of records -one after the other - by an SQL UPDATE statement, for example. This way the log can't be circumvented, until you modify the trigger expressions calling into the stored procedures.

To get starting the only requirement is your DBC is VFP9 compatible, which means it will support execution of VFP9 language as stored procedures are addded that make use of the VFP9 feature of scattering a record to an object and inserting from it.

The very basic principle of VFP Transactions is hooking into whatever currently is already established as stored procedures and triggers in a DBC. Establishing a Transactionlog is as easy as calling a script while the DBC is open exclusive. VFP Transactionlog procedures will be appended to any existing procedures and triggers calls will be modified, if already existing from referential integrity triggers, for example, to make a call into the VFPlog stored procedure, which is the starting point of persisting changes into a transaction log.

The working principle is establishing a ququ that takes in log info objecrts including the data modified (as record objects - the already mentioned VFP9 feature I'm exhaustively using) and a timer processing that queue. Initial to queueing some head meta data is stored, but more on the details later. Besides the queue and timer estqablishing the actual logging part, the last ingredient requires your intention, when you actually already make use of VFPs transaction capabilities. And you likely do, if you're interested in having a transaction log in your DBC.

As should be known VFP transactions are actually not logged and the feature they offer is a reliable commit or rollback of all operatoins done within a transaction. The few transactin related commnds in VFP are quite self explanatory BEGIN TRANSACTION begins a manual transaction, END TRANSACTION commmits it, ROLLBACK rolls back changes made in a transaction and TXNLevel() is a function returning the current transaction level of the current datasession. Transactions can't be named, but TxnLevel() already hints on the ability to nest several transacations. The effect of transactions are rigorous locks on all DBFs involved in a transaction, whcih lock out any other user trying to do something with the same tables that are already involved in the transaction of another user, so the best practice is to keep them as short as possible. When you buffer all changes of a user in tables and finally have a save routine that commits the buffers that's the moment to start a transaction as best practice, store all buffers of tables invovled - for example an order and all its order details - to then commit the flushed buffers by ending the transaction or rolling back all changes when something fails. So far just a very breif description on how to make use of transactions in VFP.

## Usage

The technical part of it is that you should change your ways in only a very slight but subtle difference from directly using BEGIN TRANSACTION, END TRANSACTION, and ROLLBACK and use the methods VFP Transactions provides in the form of methods of a \_VFP.Transactions object, that is established for transaction logging.

## preparing your code base for usgae of VFPTransactions

Make the follwing replacements in your code:
```
BEGIN TRANSACTION must be replaced by _vfp.Transactions.Begin(Set('DataSession'))
END TRANSACION must be replaced by _vfp.Transactions.End(Set('DataSession'))
ROLLBACK must be replaced by _vfp.Transactions.Rollback(Set('DataSession'))
```
This can be done 1:! at any place without putting any deeper thought to it. Even if your framework makes use of these VFP commands in objects managing transactions this way, VFPTransactions will just add a further layer to this and take over making the actual VFP calls to really begin, end&/commit or rollback a transaction.

One advantage of this is objects will be created and stored in a collection within the VFPTransaction object world, that when destroyed for any reasons - also  system crashes - end with ROLLBACK by default. So any unplanned exit puts data back into the previouly known valid state (as long as the crash isn't really somethign very disruptive like a power outage without a UPS.

Besdies these changes, obviously you have to add the VFPTransactions stored procedures to your DBC and set all insert/update/delete triggers to call into them. But that's also taken care of with a simple call of createorupdatetransactionlog.prg:
```
Do createorupdatetransactionlog WITH "c:\path\to\yourdatabse.dbc"
```
or when you prefer and CD into the prgs directory or add it to SET PATH and/or SET PROCEDURE:
```
createorupdatetransactionlog("c:\path\to\yourdatabse.dbc")
```
Congratulations, you're almost there already.

### establish the transaction log as first thing in your application code

The only other change in your project will be estblishcing the main \_vfp.Transactions object that's obviously a prerequisie of making these calls. Well, or do nothing. The good news is that the stored procedure added to the insert/update/delete triggers of your DBC tables don't rely on \_VFP.Transactions being established beforehand, the first trigger queueing the first record of the first table involved in any modification by SQL or xbase code will also establish \_VFP.Transactions. It's still recommended that you take it into your hands to do so, which also is a very simple single line of code in your main.prg:

```
Open Database _yourdatabase_.dbc && which includes the stored procedures of VFPTransactionlog
Set Database To _yourdatabase_
dbcCreateObject("TransactionLogManager")
```
And then watch it work. By default this will establish a subdirectory yourdatabaseLog where all log related data will be created. The srtructure of which is described in documentation of the project.

And now? Do you need to change your code base to do anything in transactions so they are getting attention deom the TransactionLogManager? No. VFPTransactions actually also works without establishing transactions in your project, becasue it also autocommits changes by timer, it's only missing anything you do in tables not covered by triggers of a DBC, but that's just obviously leaving the scope of the Trnansaction log covering all tables of a DBC.

Everything about VFPTransactions is contained within the stored procedures, so there is no way of stepping on your own foot by unloading any classlibraries from meory. The destroy events of all involved classes are doing their best to gracefully exit all transactions and put the transaction log in a healthy state. VFPTrnansactions therefore also hooks into the ON SHUTDOWN event. Whatever you want to do there, establish your ON SHUTDOWN first, for example ON SHUTDOWN QUIT or ON SHUTDOWN DO tidyup() and the initiqalisation of the TransactionLogManager will override this with its own release call, but within that release will finally change back to what you defined beforehand.

This also means there is no reason to include any finishing call to \_vfp.Transactions in your tidyup code. If you wnat to close the database and fear \_vfp.Transactions to fail in such cases, you can finish it anyway by calling
```
_vfp.Transactions.Release()
```

But you can obviously also make this call at any time you  want to pause transacrtions and do some bulk operations not logged. Then reestablish it by dbcCreateObject("TransactionLogManager").

It can take a while for \_vfp.Transactions to release as it also closes all transactions and finishes committing any data to DBC tables and the log. That's already all to know about using VFP Transactions.

## The transaction log

To be continued
