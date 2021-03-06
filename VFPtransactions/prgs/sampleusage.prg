* Order usage example

* 3 steps are done here
* Step 1: Establish stored procs in a DBC
* Step 2: start VFPTransactions - what would be done at application start in main.prg
* Step 3: Add a sample order into the database and let VFPTransactions handle the triggers producing transaction log data.

* Step 1: Establish stored procs in a DBC
? 'establish stored procs'
* Here I'm using a DBC with a simple order table hierachy for which VFP referential integrity RI code is already in the stored procs and for which some triggers are already set
* Copying a template directory
Local lcInitialDataDir, lcDataDir, lcSampledataDBC
Clear
Cd Addbs(JustPath(Sys(16)))
lcInitialDataDir = Sys(2014,JustPath(Sys(16))+'\..\initialdata\*.*')
lcDataDir        = Sys(2014,JustPath(Sys(16))+'\..\data_with_log'+Sys(2015)+'\*.*')
lcSampledataDBC  = JustPath(m.lcDataDir)+'\sampledatabase.dbc'

*? lcInitialDataDir
*? lcDataDir
*? lcSampledataDBC

If ADir(laFiles,lcInitialDataDir)<11
   Error "inital data directory is missing files, I won't proceed with an unknown set of initialdata"
   Return .F.
EndIf 

If Pemstatus(_vfp,'Transactions',5) And Vartype(_vfp.Transactions)='O'
   _vfp.Transactions.Release()
Endif
Close Tables All
Close Databases All

MkDir (JustPath(lcDataDir))
Copy Files (lcInitialDataDir) To (lcDataDir)

* add stored procs to the copied database (just once, further calls just for updating procedures, when updates are available)
create_or_alter_vfptransactions_storedprocedures(lcSampledataDBC)

* Step 2 Start VFPTransactions
? 'start VFPTransactions'
On Shutdown Quit
dbcCreateObject("TransactionLogManager")

* Step 3 usual ways to add some VFP data into a table hierarchy for orders
? 'add an order fully nested within a transaction'
Local liOrderId

* use VFPs buffering
Set Multilocks On
CursorSetProp("Buffering",5,0)

* explicitly open tables to get default buffering for workarea 0
* (See note in CURSORSETPROP about buffering in nWorkarea=0)
Use sampledatabase!orders in 0
Use sampledatabase!orderitems In 0

* combined with a transaction From start to end
_VFP.Transactions.Begin(Set("Datasession"))
* start a new order
Insert Into Orders (customerid) values (1)
liOrderId = Orders.id
* add an orderitem
Insert Into OrderItems (orderid, productid) Values (m.liOrderId, 1)

* Now save the buffers data
Local llRollback
llRollback = .T.
If TableUpdate(2,.t.,"orders")
   * order save succeeded
   If TableUpdate(2,.t.,"orderitems")
      * orderitem save succeeded, so end transacion...
      _VFP.Transactions.End(Set("Datasession"))
      * and don't rollback
      llRollback = .F.
   EndIf
EndIf

If llRollback
   * something didn't work
   _VFP.Transactions.Rollback(Set("Datasession"))   
EndIf 

? 'now a slight stastus update from shopping staus to finally ordered in a separate transaction'
* and update status to ordered
_VFP.Transactions.Begin(Set("Datasession"))
Update orders set status = 1 where id = m.liOrderId
_VFP.Transactions.End(Set("Datasession"))



? 'And now an order only nesting the last buffer saves into a transaction'
* combined with a transaction only at the end of the process
* from tableupdate storing the buffer to end
* start a new order
Insert Into Orders (customerid) values (1)
liOrderId = Orders.id
* add an orderitem
Insert Into OrderItems (orderid, productid) Values (m.liOrderId, 1)

* Now begin a transaction to save the data
? 'data is buffered and buffers will now be committed within a transaction'
_VFP.Transactions.Begin(Set("Datasession"))
Local llRollback
llRollback = .T.
If TableUpdate(2,.t.,"orders")
   * order save succeeded
   If TableUpdate(2,.t.,"orderitems")
      * orderitem save succeeded, so end transacion...
      _VFP.Transactions.End(Set("Datasession"))
      * and don'T rollback
      llRollback = .F.
   EndIf
EndIf

If llRollback
   * something didn't work
   _VFP.Transactions.Rollback(Set("Datasession"))   
EndIf 

? 'again a little extra transaction for the status change from shopping to ordered'
* and update status to ordered
_VFP.Transactions.Begin(Set("Datasession"))
Update orders set status = 1 where id = m.liOrderId
? 'But this time the customer decides to not submit the order to the ordered stat and reverts the status to 0 by rollback'
_VFP.Transactions.Rollback(Set("Datasession"))
? 'This time not because there would have been some technical difficulty...'


? 'Once more a full order that we intentionally rollback. This time from customer 2'
* combined with a transaction only at the end of the process
* from tableupdate storing the buffer to end
* start a new order
_VFP.Transactions.Begin(Set("Datasession"))
Insert Into Orders (customerid) values (2)
liOrderId = Orders.id
* add an orderitem
Insert Into OrderItems (orderid, productid) Values (m.liOrderId, 1)
_VFP.Transactions.Rollback(Set("Datasession"))