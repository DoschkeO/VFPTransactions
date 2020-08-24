#Define DEBUGMODE .T.
#Define BASEDIR AddBS(GetEnv("TEMP"))

#IF DEBUGMODE
    Set Debugout To BASEDIR+"sampleusage.log"
#ENDIF    
On Error debugout Error(), Message(), Program(), Lineno()

Cd JustPath(_vfp.ActiveProject.name)
Cd data
Close Databases all
Open Database sampledatabase

On Shutdown Quit
dbcCreateObject("TransactionLogManager")

* sample usage begins
* The datasession we're working in
Local lnDatasessionId
lnDatasessionId = Set("Datasession")

Local llSafety
llSafety = (Set("Safety")=='ON')
Use sampletable In 0 Exclusive 
Alter Table sampletable alter column id integer autoinc nextvalue 1 step 1
Set Safety Off
Zap In sampletable
If llSafety
   Set Safety On
EndIf 
Use Dbf() Shared

Set Database To sampledatabase
debugout datetime(),'Working in Datasession',m.lnDatasessionId, 'Transaction level:', Txnlevel()
_vfp.Transactions.Begin(   m.lnDatasessionId)
debugout datetime(), 'Working in Datasession',m.lnDatasessionId, 'Transaction level:', Txnlevel()

debugout datetime(), 'LogQueue count is ', _vfp.TransactionLogQueue.Count
debugout datetime(), 'Inserting 2 rows'
Insert into sampletable (cData) values ('Hello')
Insert into sampletable (cData) values ('World')
debugout datetime(), 'LogQueue count is ', _vfp.TransactionLogQueue.Count

debugout datetime(), 'rolling back these records.'
_vfp.Transactions.Rollback(m.lnDatasessionId)
debugout datetime(), 'LogQueue count is ', _vfp.TransactionLogQueue.Count

debugout datetime(), 'Working in Datasession',m.lnDatasessionId, 'Transaction level:', Txnlevel()
_vfp.Transactions.Begin(   m.lnDatasessionId)
debugout datetime(), 'Working in Datasession',m.lnDatasessionId, 'Transaction level:', Txnlevel()

debugout datetime(), 'LogQueue count is ', _vfp.TransactionLogQueue.Count
debugout datetime(), 'Inserting two more rows.'
Insert into sampletable (cData) values ('Bye')
Insert into sampletable (cData) values ('World')
debugout datetime(), 'LogQueue count is ', _vfp.TransactionLogQueue.Count

lnID = sampletable.id
debugout datetime(), 'committing the records this time'
_vfp.Transactions.Commit(m.lnDatasessionId)
debugout datetime(), 'LogQueue count is ', _vfp.TransactionLogQueue.Count

debugout datetime(), 'Working in Datasession',m.lnDatasessionId, 'Transaction level:', Txnlevel()

debugout datetime(), 'Do a last change outside of any transaction...'
Update sampletable set cData = 'Olaf' Where id = m.lnID
debugout datetime(), 'LogQueue count is ', _vfp.TransactionLogQueue.Count

debugout datetime(), 'aftermath: Ids 3+4 remain'
Select sampletable
Go top
Browse Name oBrowse Nowait
oBrowse.Left = 400

Set Coverage To BASEDIR + "end.log"
Do while _vfp.TransactionLogQueue.Count>0
   debugout datetime(), 'LogQueue count is ', _vfp.TransactionLogQueue.Count
   Doevents
   Wait Timeout .25
EndDo 
debugout datetime(), '...And now the last change also was logged.'
* Anything>0 now will surprise
debugout datetime(), 'LogQueue count is ', _vfp.TransactionLogQueue.Count