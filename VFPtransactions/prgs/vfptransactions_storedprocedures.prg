*** VFPTransactions BEGIN ***
*     Do not remove!        *
*  This marks the start of  *
*  VFPTransactions stored   *
*  procedures.              *
*****************************

* Main ideas:
* One TransactionLogManager for all datasessions and transactions (master).
* One SessionManager per datasession (a delegate for doing the logging and managing its own sessions/transactions)
* One simple TransactionManager object per combination of DataSession id and transaction level, mainly objectifying
* begin/commit/rollback.
* A queue for fast intake of data to log, returning control to the main application as early as the to be logged
* change is queued.
* A timer for handling the queued log objects and autocommiting log data itself in part even before the native
* transaction ends.

* A few #Defines
#Define DEBUGMODE .F.

* Log Status - the stages of logging
#Define LOGSTATUSINFOCREATED 0
#Define LOGSTATUSQUEUED 1
#Define LOGSTATUSHEADDATARECORDED 2
#Define LOGSTATUSLOGGED 3
#Define LOGSTATUSTRANSACTIONROLLEDBACK 4
#Define LOGSTATUSTRANSACTIONCOMMITTED 5

Procedure VFPLog()
   Lparameters toLogInfo, tlDoLog

   If Not m.tlDoLog
      Return .F.
   Endif

   * Add transaction log manager, if missing
   If !Pemstatus( _vfp,'Transactions', 5)
      AddProperty(_vfp,'Transactions', .Null. )
   Endif
   If Isnull(_vfp.Transactions)
      * if none exists, create it!
      _vfp.Transactions = Createobject('TransactionLogManager')
   Endif

   * Add LogQueue, if missing
   * The queueing helps to keep the initial trigger call time to a minimum
   * and only store a head record of the trigger event within the current
   * session and transaction.
   If Not Pemstatus(_vfp,"TransactionLogQueue", 5)
      AddProperty(  _vfp,'TransactionLogQueue', .Null.)
   Endif
   If Isnull(_vfp.TransactionLogQueue)
      _vfp.TransactionLogQueue = Createobject('LogQueue')
   Endif

   If Vartype(_vfp.TransactionLogQueue)='O'
      * First Queue, actual logging will be initiated by TransactionLogTimer
      _vfp.TransactionLogQueue.Queue(m.toLogInfo)
   Endif

   Return m.tlDoLog
Endproc

Procedure LogRecord()
   Lparameters tcTrigger

   Local lcDBF, loLogInfo, loRecord
   Local Array laFields[1]

   * Instantly capture some values
   Scatter     Memo                        Name loRecord

   loLogInfo = Createobject('empty')
   AddProperty(m.loLogInfo, 'aTableDefinition[1]')
   =Afields   (m.loLogInfo.aTableDefinition      )

   * LogInfo
   AddProperty(m.loLogInfo, 'cLogType'          , 'T'                              ) && Trigger
   AddProperty(m.loLogInfo, 'iLogId'            , 0                                )
   AddProperty(m.loLogInfo, 'iTransactionLogId' , 0                                )
   AddProperty(m.loLogInfo, 'oRecord'           , loRecord                         )
   AddProperty(m.loLogInfo, 'lLogRecord'        , .T.                              )
   AddProperty(m.loLogInfo, 'tLogTime'          , Datetime()                       )
   AddProperty(m.loLogInfo, 'iRecno'            , Recno()                          )
   AddProperty(m.loLogInfo, 'lDeleted'          , Deleted()                        )
   AddProperty(m.loLogInfo, 'cTrigger'          , tcTrigger                        )
   AddProperty(m.loLogInfo, 'iLogStatus'        , LOGSTATUSINFOCREATED             )
   AddProperty(m.loLogInfo, 'mDBF'              , Dbf()                            )
   AddProperty(m.loLogInfo, 'mDBC'              , Dbc()                            )
   AddProperty(m.loLogInfo, 'mCursorDBC'        , Lower(CursorGetProp('Database')) )
   AddProperty(m.loLogInfo, 'cLogTablenameExpr' , .Null.                           )
   AddProperty(m.loLogInfo, 'cMetaTablenameExpr', .Null.                           )
   AddProperty(m.loLogInfo, 'iDatasessionId'    , Set('DataSession')               )
   AddProperty(m.loLogInfo, 'iTransactionLevel' , Txnlevel()                       )
   AddProperty(m.loLogInfo, 'mCaller'           , Sys(16,Max(0,Program(-1)-1))+Id())

   Return m.loLogInfo
Endproc

Define Class DataLogger As Session
   Abstract           = .T.
   DataSession        =  1 && 'default', no new session
   cBaseDir           = ''
   cLogPath           = ''
   cLogDir            = ''
   cLogDBC            = ''
   cLogDBF            = ''
   cLogMetaDBF        = ''
   lLogRecord         = .T.
   lUseTableSignature = .T.
   cLogTablenameExpr  = 'Juststem(m.toLogInfo.mDBF)+m.lcTableSignature'
   cMetaTablenameExpr = 'm.lcLogAlias+"Meta"'
   nBuffering         = 5 && optimistic table buffering

   * The reason to base this on Sessions is not that it's data related
   * but mainly because it's a class with a smaller memory footprint than
   * the Custom baseclass.
   * Of course with exceptions. More on that in the concrete classes

   * Major idea of the data logger is that logging data is simplest by keeping a copy. The SCATTER NAME and then
   * INSERT FROM NAME or GATHER NAME operations make this simple, too. Another idea would be finding out changes
   * and only storing changed columns. That would also be friendlier about hard drive space usage, but actually
   * would involve much more analysis time you don't have at log time. The log itslef has all infromation necvessary
   * to aggregate this minimal log data as postprocessing the logged data.
   *
   * Next thought is, that it pays to record some meta data. Just a small hint why this should be done at all:
   * It wouldn't fit the purpose of logging the deleted status of a record by making a copy of it and deleting that,
   * too. Should that really mean the deleted log record IS part of the log and just recording the deletion status
   * or is the a record that was removed from the log?
   *
   * Also other parts o information are volatile, if you don't record them. The record number at log time is some-
   * thing that can later change with operations like PACK. And which user (identified by Windows account) did a
   * change also must be recorded separately in meta data.
   *
   * The third thought going into the design of this logging is, that the tables you log could be at maximum of
   * allowed specifications, ie maximum number of fields. So the meta data is logged in a separate dbf and not added
   * as a bunch of fields. There would only be one pro in added fields, as they would guarantee the meta data to
   * relate to the record its part of, it could not go out of sync. There's a simple con argument though, that those
   * meta data field names would then become reserved names for any data and that's the bigger restriction. You could
   * give the meta data fields complicated names that are unlikely, but you'd always fail with one thing: Keeping a
   * trnasaction log of the transaction log itself. It's not necessarily a goal to be able to apply the transaction
   * logging system to the transaction log itself, but it would be a fine quality mark to not step on your own foot
   * in that aspect. Besides it would be really bad, if you couldn't keep a relationship of data intact. The log will
   * not consist of a single DBF listing all changes anyway. That's only a theoretical possibility like the minimal
   * log data aggregation postprocessing done live. I won't go that route, as a simpler 1:1 logging is much easier
   * to verify and to postprocess and use in different ways. A Replication prrocess, for example, will profit very much
   * of records being stored in the composition they are stored in the master database, so replication copies are easily
   * done.

   Procedure Init()
      *Set Multilocks On
      Local lcLogPath
      * Determine Log Base Path
      lcLogPath = Lower(Sys(16))
      lcLogPath = Alltrim(Substr(m.lcLogPath,At('\',lcLogPath)-2))
      This.cLogPath = Ltrim(Addbs(Justpath(m.lcLogPath)))+Juststem(m.lcLogPath)+'Log\'

      * Determine constants for a current VFP process used as unique log key.
      Local lcIDFilter
      lcIDFilter = Chrtran(Lower(Id()),'AÀÁÂÃÄÆÅBCÇDÐEÈÉÊËFGHIÌÍÎÏJKLMNÑOÒÓÔÕÖŒØPQRSŠTUÙÚÛÜVWXYÝŸZþ_'  ;
         +                             'aàáâãäæåbßcçdðeèéêëfƒghiìíîïjklmnñoòóôõöœøpqrsštuùúûüvwxyýÿzÞ' ;
         +                             '0123456789','')

      This.cBaseDir = Chrtran(Lower(Id()),m.lcIDFilter,Replicate('_',Len(m.lcIDFilter)))+'_'+Alltrim(Str(_vfp.ProcessID))
      * base Dir should be an allowed as dir name and makes all names unique when collecting log data from clients
      * to a central process handling their processing for a global log and replication, etc.

      * Jedi gesture - 'You don't have to understand this'
      Return Not This.Abstract
   Endproc

   Procedure cLogDir_Assign()
      Lparameters tvNewValue

      Local lcLogDBC, lcLogPath

      lcLogDBC = This.cLogDBC
      If !Empty(m.lcLogDBC)
         Try
            Set Database To (m.lcLogDBC)
            If Lower(Set('Database'))==Lower(Juststem(m.lcLogDBC))
               This.CommitLog()
               Close Database
            Endif
         Catch
            *
         Endtry
      Endif

      This.cLogDir = m.tvNewValue
      This.cLogDBC = Addbs(This.cLogPath)+This.cLogDir+'\log.dbc'
      This.CheckDir()
   Endproc

   Procedure CheckDir()
      If Not Directory(This.cLogPath,1)
         Mkdir (This.cLogPath)
      Endif
      If Not Directory(Justpath(This.cLogDBC),1)
         Mkdir (Justpath(This.cLogDBC))
      Endif
   Endproc

   Protected Procedure OpenOrCreateLog()
      * Create a DBC even within a running transaction
      * ----------------------------------------------
      * (usually not possible, see VFP help topic Begin Transaction => CREATE DATABASE listed as not suported command)
      * Not every object will later make use of that, but it's available in case a class enhancement
      * justifies storing some data in its own database.

      * Main use in
      * -----------
      * 1. The Transaction Manager: a database for the general DBC log
      * 2. Session Managers: a database for each separate session
      * 3. Transactions: (Ideally) a database per transaction

      Local llCreate
      Try
         Set Database To (This.cLogDBC)
      Catch
         Try
            Open Database (This.cLogDBC) Shared
            Set Database To (This.cLogDBC)
         Catch
            llCreate = .T.
         Endtry
      Endtry

      If Not llCreate
         Return .T.
      EndIf
      
      Local array laDir[1]
      If ADir(laDir,This.cLogDBC) = 1
         Try
            Open Database (This.cLogDBC) Shared
            Set Database To (This.cLogDBC)
         Catch
            *
         EndTry
         
         Return .F.
      Endif

      * One difficulty in all of this: Within transactions some commands and functions are forbidden.
      * CREATE DATABASE and CREATE TABLE are some of them. But that can be compensated by CREATE CURSOR and COPY TO
      * 1. A DBC in itself is not much more than a free DBF, we just need to adjust one bit with Fwrite
      * 2. COPY TO enables to make DBFs part of a DBC with its DATBASE clause, so we're fine in that aspect, too
      * 3. Transactions are scoped to a session, so some things could also simply be outsourced to be done
      * within another session. It tunrs out creating databases not so. If Txnlevel()>1 for any session you
      * can't CREATE DATABASE, CREATE TABLE iis trickier, but I decide to go with CREATE CURSOR and COPY TO instead.

      Local lcAliasName, lnCWA
      lcAliasName = '__od_logdbc_'+Sys(2015)

      lnCWA = Select(0)
      Select 0
      Create Cursor (m.lcAliasName) ;
         (objectid I, parentid I, objecttype C(10), objectname C(128), property M NoCPTran, Code M NoCPTran, riinfo C(6), User M)
      Index On Str(parentid)+objecttype+Lower(objectname) Tag objectname  Collate 'Machine' For !Deleted()
      Index On Str(parentid)+objecttype Tag objecttype Collate 'Machine' For !Deleted()
      Insert Into (m.lcAliasName) Values (1,1,'Database','Database',0h0B0000000100180000000A,'','','')
      Insert Into (m.lcAliasName) Values (2,1,'Database','TransactionLog','','','','')
      Insert Into (m.lcAliasName) Values (3,1,'Database','StoredProceduresSource','','','','')
      Insert Into (m.lcAliasName) Values (4,1,'Database','StoredProceduresObject','','','','')
      Insert Into (m.lcAliasName) Values (5,1,'Database','StoredProceduresDependencies','','','','')

      * Copy that including CDX to disc:
      Copy To (This.cLogDBC) With Cdx
      Use

      * Need to change 1 bit as flag for dbc
      Local lnFH
      lnFH = Fopen(This.cLogDBC,12)
      Fseek(m.lnFH,28)
      Fwrite(m.lnFH,Chr(7),1)
      Fclose(m.lnFH)

      If m.lnCWA>0 And m.lnCWA<>Select(0)
         Select (m.lnCWA)
      Endif
      Open Database (This.cLogDBC) Shared
      
      Return .T.
   Endproc

   Procedure Log()
      Lparameters toLogInfo

      * determine log DBC and DBFs, eventually generate them
      Local lcLogPath, lcLogDBC, lcLogAlias, lcLogDBF, lcLogMetaAlias, lcLogMetaDBF, lnField, lnCWA
      Local Array laDir[1]

      lnCWA = Select(0)
      lcLogPath = This.cLogPath
      lcLogDBC  = This.cLogDBC
      If Not This.OpenOrCreateLog()
         * no success this time, try again later
         If m.lnCWA>0 And m.lnCWA<>Select(0)
            Select (m.lnCWA)
         Endif
         Return .F.
      EndIf 

      If Not Used('alltransactionevents')
         * important to get access
         Use transactionlog!alltransactionevents In 0 Shared
      Endif
      If Not Used('alltransactionevents')
         * no access to alltransactionevents.dbf? 
         * then keep toLogInfo in the queue and try again later
         If m.lnCWA>0 And m.lnCWA<>Select(0)
            Select (m.lnCWA)
         Endif
         Return .F.
      Endif

      If m.toLogInfo.lLogRecord And This.lLogRecord And This.lUseTableSignature And Type('m.toLogInfo.aTableDefinition',1)='A'
         Local lcTableSignature, lnField, lnCount
         * Determine a table signature
         * to identify and reidentify the current log table
         lcTableSignature = ''
         For   m.lnField = 1 To Alen(m.toLogInfo.aTableDefinition,1)
            * table structure signature
            For m.lnCount = 1 To 6
               lcTableSignature = m.lcTableSignature + Transform(m.toLogInfo.aTableDefinition[m.lnField,m.lnCount])
            Endfor
         Endfor
         * Different structure (alter table in between triggers) => new log file
         lcTableSignature = 'crc'+Sys(2007,lcTableSignature,-1,1)
      Endif

      If m.toLogInfo.lLogRecord And This.lLogRecord
         lcLogAlias    = Evaluate(Nvl(m.toLogInfo.cLogTablenameExpr,  This.cLogTablenameExpr))
         lcLogDBF      = Addbs(Justpath(m.lcLogDBC)) + lcLogAlias     + '.dbf'
         This.cLogDBF  = m.lcLogDBF
      Endif

      lcLogMetaAlias   = Evaluate(Nvl(m.toLogInfo.cMetaTablenameExpr, This.cMetaTablenameExpr))
      lcLogMetaDBF     = Addbs(Justpath(m.lcLogDBC)) + lcLogMetaAlias + '.dbf'
      This.cLogMetaDBF = m.lcLogMetaDBF

      If Adir(laDir, m.lcLogMetaDBF) = 0 And Not (lcLogMetaAlias=='alltriggerevents') && covered by alltransactionevents
         This.CreateLogMetaDBF(m.lcLogMetaDBF)
      Endif

      If m.toLogInfo.lLogRecord And This.lLogRecord And Type('m.toLogInfo.aTableDefinition',1)='A'
         If Adir(laDir, m.lcLogDBF) = 0
            For lnField = 1 To Alen(m.toLogInfo.aTableDefinition,1)
               m.toLogInfo.aTableDefinition[m.lnField, 7]=''
               m.toLogInfo.aTableDefinition[m.lnField, 8]=''
               m.toLogInfo.aTableDefinition[m.lnField, 9]=''
               m.toLogInfo.aTableDefinition[m.lnField,10]=''
               m.toLogInfo.aTableDefinition[m.lnField,11]=''
               m.toLogInfo.aTableDefinition[m.lnField,13]=''
               m.toLogInfo.aTableDefinition[m.lnField,14]=''
               m.toLogInfo.aTableDefinition[m.lnField,15]=''
               m.toLogInfo.aTableDefinition[m.lnField,17]=0
               m.toLogInfo.aTableDefinition[m.lnField,18]=0
            Endfor
            m.toLogInfo.aTableDefinition[1,12] = Juststem(m.lcLogDBF)

            Create Cursor (Juststem(m.lcLogDBF)) From Array m.toLogInfo.aTableDefinition
            Copy To (m.lcLogDBF) Database (Juststem(m.lcLogDBC))
            Use (m.lcLogDBF) Shared
            CursorSetProp('Buffering',This.nBuffering)
         Endif
      Endif

      * Insert log meta data
      If Not (lcLogMetaAlias =='alltriggerevents')
         Insert Into (m.lcLogMetaDBF) From Name m.toLogInfo
      Endif

      * Insert log data - the record itself
      If m.toLogInfo.lLogRecord And This.lLogRecord
         Insert Into (m.lcLogDBF)  From Name m.toLogInfo.oRecord
      Endif

      * Finally always store meta data in alltransactionevents of main transactionlog.dbc:
      If Indexseek(m.toLogInfo.iLogId, .T. , 'alltransactionevents', 'xLogId')
         If !Eof('alltransactionevents') And alltransactionevents.iLogStatus <= m.toLogInfo.iLogStatus
            Select alltransactionevents
            Gather Name m.toLogInfo Memo
         Endif
      Else
         *        Insert Into alltransactionevents From Name m.toLogInfo
         Select alltransactionevents
         Append Blank In alltransactionevents
         Gather Name m.toLogInfo Memo
      Endif

      If m.lnCWA>0 And m.lnCWA<>Select(0)
         Select (m.lnCWA)
      Endif

      Return .T.
   Endproc

   Procedure CreateLogMetaDBF()
      Lparameters tcLogMetaDBF
      Create Cursor (Juststem(m.tcLogMetaDBF)) ;
         (iLogId I, iTransactionLogId I, cLogType C(1), iLogStatus I, iDataSessionId I, iTransactionLevel I, ;
         iRecno I, lDeleted L, cTrigger C(1), mCaller M, tLogTime T)
      Copy To (m.tcLogMetaDBF) Database (Juststem(This.cLogDBC))
      Use (m.tcLogMetaDBF) Shared
      CursorSetProp('Buffering',This.nBuffering)
   Endproc
Enddefine

* DataSession=2 means this manager runs in a new separate Session.
* Therefor it can handle its data, the main transaction log of all users
* without influencing workarea and other sessions in the rest of the application
* and it enables this to work with some environment settings that only apply to
* one session.

Define Class TransactionLogManager As SessionManager
   Abstract = .F.
   DataSession = 2 && 'private', no influence of other sessions
   oSessionManagers = .Null.
   cOldShutdown = ''
   cLogPath           = ''
   cLogDBC            = ''
   cLogDBF            = ''
   cLogMetaDBF        = ''
   cLogIdDBF          = ''
   lLogRecord         = .F.
   lUseTableSignature = .F.
   cLogTablenameExpr  = '"none"'
   cMetaTablenameExpr = 'JustStem(m.toLogInfo.mDBC)+"triggerevents"'
   nBuffering         = 1 && no buffering
   lReleased          = .F.

   Procedure Init()
      Local llInstanciate
      llInstanciate = Not This.Abstract

      * Only one transactionmanageer,
      * otherwise this could get awkward with multiple sesssion and transaction objects
      If Pemstatus(_vfp,'Transactions',5)  And ;
            Vartype(_vfp.Transactions)='O' And ;
            Lower(_vfp.Transactions.Class) = 'transactionlogmanager'
         llInstanciate = .F.
      Endif

      If llInstanciate
         Set Exclusive Off
         Declare Integer Sleep In Win32API Integer nMilliseconds

         If Not Pemstatus(_vfp,'Transactions',5)
            AddProperty(_vfp,'Transactions', .Null.)
            _vfp.Transactions = This
         Endif
         llInstanciate = DataLogger::Init()

         If llInstanciate
            Set Multilocks On
            This.oSessionManagers = Createobject('EasyCollection')

            * Create LogId system table for autoinc nubmers
            * of any log objects

            lcLogPath = This.cLogPath
            This.cLogDBC = Addbs(m.lcLogPath)+'transactionlog.dbc'
            This.CheckDir()
            This.OpenOrCreateLog()

            Local lcLogDBC, lcLogIdDBF, lnCWA
            Local laDir[1]
            lcLogDBC = This.cLogDBC
            lcLogIdDBF = Addbs(Justpath(m.lcLogDBC))+'logid.dbf'
            This.cLogIdDBF = m.lcLogIdDBF

            lnCWA = Select(0)

            If Adir(laDir, m.lcLogIdDBF)=0
               If Not Directory(Justpath(m.lcLogIdDBF))
                  Mkdir (Justpath(m.lcLogIdDBF)
               Endif
               Create Cursor __od__log_id (LogId Int Autoinc Nextvalue 1 Step 1)
               Copy To (m.lcLogIdDBF) Database transactionlog
               Use
            Endif

            Local lcLogAllDBF
            lcLogAllDBF = Addbs(Justpath(m.lcLogDBC))+"alltransactionevents.dbf"
            If Adir(laDir, m.lcLogAllDBF)=0
               Create Cursor __od__logall ;
                  (iLogId I, iTransactionLogId I Null Default .Null., cLogType C(1), iLogStatus I, iDataSessionId I, iTransactionLevel I, ;
                  cTrigger C(1) Default ' ', mLogDir M, mCaller M, tLogTime T Default Datetime())
               Index On iLogId Tag xLogId && Candidate
               * As appends turn out to be more stable working than inserts, as the dbf is already oprn
               * I need to enable a shorthand double ilogid=0 from 2 processes, so no candidate index
               Copy To (m.lcLogAllDBF) Database transactionlog With Cdx
               Use (lcLogAllDBF) Shared
            Endif

            * Add LogQueue
            * The queueing helps to keep the initial trigger call time to a minimum
            * and only store a head record of the trigger event within the current
            * session and transaction.
            If Not Pemstatus(_vfp,"TransactionLogQueue",5)
               AddProperty(_vfp,'TransactionLogQueue',.Null.)
            Endif
            If Isnull(_vfp.TransactionLogQueue)
               _vfp.TransactionLogQueue = Createobject('LogQueue')
            Endif

            * SessionManager Init without DataLogger Init (already done with DataLogger::Init())
            * Just creating the first SessionLogger and TransactionManager/TransactionLogger now after the
            * logid mechanism is established
            DoDefault(.T.)

            Local loLogInfo
            loLogInfo = Createobject('empty')
            * First Log entry per TransactionLogManager sart
            * LogInfo

            AddProperty(m.loLogInfo, 'cLogType'          , 'I'                               ) && init
            AddProperty(m.loLogInfo, 'iLogId'            , This.LogId()                      )
            AddProperty(m.loLogInfo, 'lLogRecord'        , .F.                               )
            AddProperty(m.loLogInfo, 'tLogTime'          , Datetime()                        )
            AddProperty(m.loLogInfo, 'iLogStatus'        , LOGSTATUSLOGGED                   )
            AddProperty(m.loLogInfo, 'iDatasessionId'    , Set('DataSession')                )
            AddProperty(m.loLogInfo, 'iTransactionLevel' , Txnlevel()                        )
            AddProperty(m.loLogInfo, 'mDBC'              , 'all'                             )
            AddProperty(m.loLogInfo, 'cLogTablenameExpr' , .Null.                            )
            AddProperty(m.loLogInfo, 'cMetaTablenameExpr', .Null.                            )
            AddProperty(m.loLogInfo, 'mLogDir'           , ''                                )
            AddProperty(m.loLogInfo, 'mCaller'           , Sys(16,Max(0,Program(-1)-1))+Id() )
            If Not This.Log(m.loLogInfo, .T., .T.)
               _vfp.TransactionLogQueue.Queue(m.loLogInfo)
            Endif

            * LogTimer, processing the Log Queue, autocommitting log data
            If Not Pemstatus(_vfp,"TransactionLogTimer",5)
               AddProperty(_vfp,'TransactionLogTimer',.Null.)
            Endif
            If Isnull(_vfp.TransactionLogTimer)
               _vfp.TransactionLogTimer = Createobject('LogTimer')
            Endif
            _vfp.TransactionLogTimer.Reset()
            _vfp.TransactionLogTimer.Enabled = .T.

            * Hook into the shutdown to end all transactions and datasessions
            This.cOldShutdown = On('Shutdown')
            On Shutdown _vfp.Transactions.Release(.F., .T.)

            If m.lnCWA>0 And m.lnCWA<>Select(0)
               Select (m.lnCWA)
            Endif
         Endif
      Endif

      Return llInstanciate
   Endproc

   Procedure LogId()
      Local lcLogIdDBF, lnCWA, lnLogID
      lcLogIdDBF = This.cLogIdDBF

      lnCWA = Select(0)
      Use (m.lcLogIdDBF) In Select("__od__log_id") Again Alias __od__log_id
      * MakeTransactable('__od__log_id')
      Begin Transaction
      Append Blank In __od__log_id
      lnLogID = __od__log_id.LogId
      Rollback && Don't keep records in log dbf, just the autoinc nextvalue (that's not rolled back by design!)

      Use In Select("__od__log_id")
      If m.lnCWA>0 And m.lnCWA<>Select(0)
         Select (m.lnCWA)
      Endif

      Return m.lnLogID
   Endproc

   *
   *
   * Application developer interface section
   * =======================================
   * Main methods: Begin/End/Commit/Rollback just like the usual simple VFP Transaction commands
   * (Commit as an alias for End, does the same, but may be better known and preferred name to some developers)
   *
   *
   * BEGIN:
   *
   * Called as _vfp.Transactions.Begin(datasessionid)
   * Which makes clear you're starting a transaction in a given datasession.
   * To do the same as BEGIN TRANSACTION and start a transaction in the current datasession, call:
   *
   * usage: _vfp.Transactions.Begin(Set('DataSession'))
   *
   *
   * Note: omitting the parameter tnInSessionId will default to the DatasessionId 1, but most likely
   * you want to start a transaction in some other session, for example the private datasession of a form.
   *
   * In a simple applications not using multiple data sessions at all you may want to start the transaction
   * in the default DatasessionId 1, so that's the default, when you omit the parameter.
   * But you can't complain when the transaction rollback has not the effect you're used to from
   * a normal BEGIN TRANSACTION / ROLLBACK combination.
   *
   *
   * In shoirt this says you only really profit from using this transaction logger architecture when you
   * have a basic understanding of transactions at least.
   Procedure Begin()
      Lparameters tnInSessionId

      * Begin Transaction
      tnInSessionId = Evl(m.tnInSessionId, 1)
      Local loSessionManager, llSuccess
      loSessionManager = This.GetOrCreateSessionManager(m.tnInSessionId)
      If !Isnull(m.loSessionManager)
         * begin a transaction in loSessionManager and return successs status about it
         llSuccess = loSessionManager.BeginTransaction()
      Endif

      Return m.llSuccess
   Endproc

   * COMMIT:
   *
   * See END, just an alias to be able to use
   * a more usual naming convention for transactions
   Procedure Commit()
      Lparameters tnInSessionId
      * End Transaction
      Return This.End(m.tnInSessionId)
   Endproc

   * END:
   *
   * Called as _vfp.Transactions.End(datasessionid)
   * committin a transaction in a given datasession.
   * To do the same as END TRANSACTION and start a transaction in the current datasession, call:
   *
   * usage: _vfp.Transactions.End(Set('DataSession'))
   *
   *
   * WARNING: omitting the parameter tnInSessionId will default to the DatasessionId 1, the
   * transaction manager will run in its own private DataSession (DataSessionId>1) and most likely
   * you want to start a transaction in some other session (3,4,5...).
   * In a simple applications not using multiple data sessions at all you may want to start
   * the transaction in the default DatasessionId 1, so that's the default
   Procedure End()
      Lparameters tnInSessionId

      * End Transaction
      tnInSessionId = Evl(m.tnInSessionId,1)
      Local loSessionManager, llSuccess

      loSessionManager = This.GetOrCreateSessionManager(m.tnInSessionId)
      If !Isnull(m.loSessionManager)
         * End current transaction and return success status
         llSuccess = loSessionManager.CommitTransaction()
      Endif

      Return m.llSuccess
   Endproc

   * ROLLBACK:
   *
   * Called as _vfp.Transactions.Rollback(datasessionid)
   * rolling back a transaction in a given datasession.
   * To do the same as ROLLBACK and rollback a transaction in the current datasession, call:
   *
   * usage: _vfp.Transactions.Rollback(Set('DataSession'))
   *
   *
   * WARNING: omitting the parameter tnInSessionId will default to the DatasessionId 1, the
   * transaction manager will run in its own private DataSession (DataSessionId>1) and most likely
   * you want to start a transaction in some other session (3,4,5...).
   * In a simple applications not using multiple data sessions at all you may want to start
   * the transaction in the default DatasessionId 1, so that's the default
   Procedure Rollback()
      Lparameters tnInSessionId

      * Rollback
      tnInSessionId = Evl(m.tnInSessionId,1)
      Local loSessionManager, llSuccess

      loSessionManager = This.GetOrCreateSessionManager(m.tnInSessionId)
      If !Isnull(m.loSessionManager)
         * End current transaction and return successs status about it
         llSuccess = m.loSessionManager.RollbackTransaction()
      Endif

      Return m.llSuccess
   Endproc

   * Here is what actually is triggered, when a DBF trigger calls
   * the tlog Stored Proc as the entry point for a DBC based application.

   * This should not be called directly, as it needs the
   * preparation of passed in log info from the tlog() stored proc!
   *
   * It has to be public anyway, as tlog has be able to call it.
   * But imagine this to be a private procedure
   Procedure Log()
      Lparameters toLogInfo, tlHeadlog, tlOnlyHeadLog, llSuccess

      Local lnCWA && fr remembering current workarea
      lnCWA = Select(0)

      If m.tlHeadlog
         m.toLogInfo.iLogStatus = LOGSTATUSHEADDATARECORDED
         llSuccess = DataLogger::Log(m.toLogInfo)
      Endif

      * secondary importance of logging is by the session manager
      * but for now it'll only delegate this to the Transsactionlogger
      * of the current TxnLevel().
      If m.llSuccess And Not tlOnlyHeadLog
         Local loSessionManager
         loSessionManager = This.GetOrCreateSessionManager(m.toLogInfo.iDataSessionId)

         If !Isnull(m.loSessionManager)
            llSuccess = m.loSessionManager.Log(m.toLogInfo, tlHeadlog)
         Endif
      Endif

      If m.lnCWA>0 And m.lnCWA<>Select(0)
         Select (m.lnCWA)
      EndIf
      
      Return m.llSuccess
   Endproc

   *
   * Internal private Method(s).
   *
   Protected Procedure GetOrCreateSessionManager()
      Lparameters tnForSessionId

      Local lnCollectionIndex, loSessionManager, lnRememberedSession

      loSessionManager = This.oSessionManagers.Peek(Str(m.tnForSessionId))

      If Isnull(m.loSessionManager)
         * every existing session deserves a manager
         lnRememberedSession = Set('Datasession')
         If m.lnRememberedSession <> m.tnForSessionId
            Set DataSession To tnForSessionId
         Endif

         loSessionManager = Createobject('SessionManager')

         If m.lnRememberedSession <> m.tnForSessionId
            Set DataSession To m.lnRememberedSession
         Endif

         This.oSessionManagers.Pile(m.loSessionManager, Str(m.tnForSessionId))
      Endif

      Return m.loSessionManager
   Endproc

   Procedure CommitLog()
      * Store all buffered data
      Local lnCount, lnWorkarea
      Local Array laWorkareas[1]

      For lnCount=1 To Aused(m.laWorkareas)
         lnWorkarea = m.laWorkareas[m.lnCount,2]
         If CursorGetProp('Buffering', m.lnWorkarea) = 5 && Table buffered
            If Not Getnextmodified(0, m.lnWorkarea,.F.) = 0
               =Tableupdate(2, .T., m.lnWorkarea)
               #If DEBUGMODE
               Else
                  Debugout 'Nothing new from TransactionLogManager Commit'
               #Endif
            Endif
         Endif
      Endfor

      If Not Vartype(This.oSessionManagers)='X'
         If This.oSessionManagers.Count>0
            For Each loSessionManager In This.oSessionManagers
               m.loSessionManager.CommitLog()
            Endfor
         Endif

         DoEvents Force
      Endif

      Try
         This.oSessionLogger.CommitLog()
      Catch
         *
      Endtry
   Endproc

   Procedure Release()
      Lparameters tlDontReleaseSystem, tlQuit

      If This.lReleased
         * for the case On Shutdown calls release,
         * release eventually starts the quittimer
         * the quit from there eventually causes the Destroy
         * which calls release again, this time with tlQuit = .F.

         * That's fine, but won't release any more things,
         * so just return:
         Return
      Endif
      This.lReleased = .T.

      Local loLogInfo
      loLogInfo = Createobject('empty')
      * Last Log entry per TransactionLogManager sart
      * LogInfo

      AddProperty(m.loLogInfo, 'cLogType'          , 'R'                               ) && Release
      AddProperty(m.loLogInfo, 'iLogId'            , This.LogId()                      )
      AddProperty(m.loLogInfo, 'lLogRecord'        , .F.                               )
      AddProperty(m.loLogInfo, 'tLogTime'          , Datetime()                        )
      AddProperty(m.loLogInfo, 'iLogStatus'        , LOGSTATUSLOGGED                   )
      AddProperty(m.loLogInfo, 'iDatasessionId'    , Set('DataSession')                )
      AddProperty(m.loLogInfo, 'iTransactionLevel' , Txnlevel()                        )
      AddProperty(m.loLogInfo, 'mDBC'              , 'all'                             )
      AddProperty(m.loLogInfo, 'cLogTablenameExpr' , .Null.                            )
      AddProperty(m.loLogInfo, 'cMetaTablenameExpr', .Null.                            )
      AddProperty(m.loLogInfo, 'mLogDir'           , ''                                )
      AddProperty(m.loLogInfo, 'mCaller'           , Sys(16,Max(0,Program(-1)-1))+Id() )
      =This.Log(m.loLogInfo, .T., .T.)

      _vfp.TransactionLogTimer.Enabled = .F.

      lcShutdownCommand = This.cOldShutdown
      If Atcc('_vfp.Transactions.Release',lcShutdownCommand,1)==0
         On Shutdown &lcShutdownCommand
      Else
         On Shutdown
      Endif

      If Not Vartype(This.oSessionManagers)='X'
         Do While This.oSessionManagers.Count>0
            This.oSessionManagers.Remove(This.oSessionManagers.Count)
            Sleep(Int(Rand()*100))
         Enddo
      Endif

      If tlQuit
         _Screen.AddObject(Sys(2015), 'quittimer')
      Else
         If tlDontReleaseSystem
            * Triggered by wrong destry via _vfp.transactions = .Null.
            * The TransActionLlogManager will release including it's data
            * but Queue and Timer remain, though the timer becomes disabled
            * enabling the timer should revive the system now
            * this is meant as self repair mechanism
            * It won't be perfect, but may keep the log alive longer than
            * just giving up on it.
         Else
            * explicitly called either _vfp.Transactions.Release() or
            * _VFp.Transactions.Release(.F.,.T.) to release including the system
            * remove all helper objects and the transaction log manager itself
            Try
               _vfp.TransactionLogTimer = .Null.
               Removeproperty(_vfp,"TransactionLogTimer")
            Catch
               *
            Endtry

            Try
               _vfp.TransactionLogQueue = .Null.
               Removeproperty(_vfp,"TransactionLogQueue")
            Catch
               *
            Endtry

            Try
               _vfp.Transactions = .Null.
               Removeproperty(_vfp,"Transactions")
            Catch
               *
            Endtry
         Endif
      Endif

      DoEvents Force
      Return DoDefault()
   Endproc

   Procedure Destroy()
      Local liActiveSession, lcActiveDBC, lcTransactionLogDBC, lnSession, lnWorkarea
      Local Array laSessions[1]
      Local Array laWorkareas[1]

      liActiveSession = Set("Datasession")
      lcActiveDBC     = Set("Database")

      * release all loggers etc.
      This.Release(.T.)

      * Close all Tables of the DBC open in other DataSessions (!)
      Try
         Set Database To transactionlog
         lcTransactionLogDBC = Dbc()
      Catch
         lcTransactionLogDBC = ""
      Endtry

      * Close all tables within the TransactionLogManager DataSession
      Close Tables All

      For lnSession = 1 To Asessions(laSessions)
         Set DataSession To (m.laSessions[m.lnSession])

         For lnWorkarea = 1 To Aused(laWorkareas, m.laSessions[lnSession])
            If Lower(CursorGetProp("Database",  m.laWorkareas[m.lnWorkarea,2]))==Lower(m.lcTransactionLogDBC)
               Use In (m.laWorkareas[m.lnWorkarea,2])
            Endif
         Endfor
      Endfor

      Set DataSession To (m.liActiveSession)

      Try
         Set Database To transactionlog
         Close Database
      Catch
         *
      Endtry

      If Dbused(m.lcActiveDBC)
         Set Database To (m.lcActiveDBC)
      Else
         Set Database To
      Endif
   Endproc
Enddefine

Define Class SessionManager As DataLogger
   Abstract    = .F.
   oSessionLogger = .Null.
   oTransactionManagers = .Null.

   Procedure Init()
      Lparameters tlForTransactionLogManager

      Local llInstanciate

      If m.tlForTransactionLogManager
         llInstanciate = .T.
      Else
         llInstanciate = DoDefault()

         If llInstanciate
            Set Multilocks On
            This.oTransactionManagers = Createobject('EasyCollection')
            This.oSessionLogger = Createobject('SessionLogger', Set("Datasession"), Txnlevel())

            * No matter at what level we are right now, add a first logger for the
            * current transaction level
            Local loTransactionManager
            loTransactionManager = Createobject('TransactionManager', Justpath(This.oSessionLogger.cLogDBC), .T.)

            This.oTransactionManagers.Pile(m.loTransactionManager, Str(Txnlevel()))
         Endif
      Endif

      Return m.llInstanciate
   Endproc

   Procedure cLogDir_Assign()
      Lparameters tvNewValue

      This.cLogDir = m.tvNewValue
   Endproc

   Procedure Log()
      Lparameters toLogInfo, tlHeadlog
      Local Array laDir[1]

      Local loTransactionManager, lnCWA, llSuccess
      loTransactionManager = This.GetTransactionByLevel(Txnlevel())
      If !Isnull(m.loTransactionManager)
         toLogInfo.iTransactionLogId = m.loTransactionManager.oTransactionLogger.iTransactionLogId
      Endif

      If Not m.tlHeadlog
         llSuccess = m.loTransactionManager.Log(m.toLogInfo)
         If m.llSuccess
            m.toLogInfo.iLogStatus = LOGSTATUSLOGGED
         EndIf
      Endif

      lnCWA = Select(0)
      If m.tlHeadlog
         * normal session head/meta data logging
         llSuccess = This.oSessionLogger.Log(m.toLogInfo)

         * Also taking care of a TransactionLogmanager task
         * in a datasession and transaction the transactionlogmanagre doesn't participate in
         * but that's the job of a session manager, too, it runs in the datasession and thus also transaction this happens in
         Assert Set("Datasession")=m.toLogInfo.iDataSessionId And Txnlevel()=m.toLogInfo.iTransactionLevel Message 'Huh?'
         Local lcLogMetaDBF, lcLogMetaAlias
         lcLogMetaDBF = _vfp.Transactions.cLogMetaDBF

         lcLogMetaAlias = Juststem(m.lcLogMetaDBF)+"_s"+Transform(m.toLogInfo.iDataSessionId)+"_t"+Transform(m.toLogInfo.iTransactionLevel)
         lcLogMetaDBF = Addbs(Justpath(m.lcLogMetaDBF))+m.lcLogMetaAlias+'.dbf'
         If Adir(laDir, m.lcLogMetaDBF)=0
            Create Cursor (m.lcLogMetaAlias) ;
               (iLogId I, iTransactionLogId I, cLogType C(1), iLogStatus I, iDataSessionId I, iTransactionLevel I, ;
               cTrigger C(1), mLogDir M, mCaller M, tLogTime T)
            Copy To (m.lcLogMetaDBF) Database transactionlog
            Use (m.lcLogMetaDBF) Shared
            lcLogMetaAlias = Alias()
         Endif
         If !Used(lcLogMetaAlias)
            Use (m.lcLogMetaDBF) In 0 Shared
         Endif
         Select (m.lcLogMetaAlias)
         Append Blank In (lcLogMetaAlias)
         Gather Name m.toLogInfo Memo
         * the rest will be done in This.Log() methoded called from LogTimer
      Endif

      If m.lnCWA>0 And m.lnCWA<>Select(0)
         Select (m.lnCWA)
      Endif

      Return m.llSuccess
   Endproc

   Protected Procedure GetTransactionIndex()
      Lparameters tnTXNLevel

      Local lnTransactionIndex
      lnTransactionIndex = This.oTransactionManagers.GetKey(Str(m.tnTXNLevel))

      Return m.lnTransactionIndex
   Endproc

   Protected Procedure GetTransactionByLevel()
      Lparameters tnTXNLevel
      Local lnCollectionIndex, loTransaction

      lnCollectionIndex = This.GetTransactionIndex(m.tnTXNLevel)
      If !Empty(m.lnCollectionIndex)
         loTransaction = This.oTransactionManagers.Item(m.lnCollectionIndex)
      Else
         loTransaction = .Null.
      Endif

      Return m.loTransaction
   Endproc

   Protected Procedure GetTransactionByCollectionIndex()
      Lparameters tnCollectionIndex
      Local loTransaction

      If !Empty(m.tnCollectionIndex)
         loTransaction = This.oTransactionManagers.Item(m.tnCollectionIndex)
      Else
         loTransaction = .Null.
      Endif

      Return m.loTransaction
   Endproc

   Procedure BeginTransaction()
      Local loTransactionManager, llSuccess

      * begin a transaction in loSessionManager and return success
      loTransactionManager = Createobject('TransactionManager', Justpath(This.oSessionLogger.cLogDBC))

      If Not Isnull(m.loTransactionManager)
         This.oTransactionManagers.Pile(m.loTransactionManager, Str(Txnlevel()))
         llSuccess = .T.
      Endif

      Return m.llSuccess
   Endproc

   Procedure CommitTransaction()
      * Commit = End Transaction
      Local lnCollectionIndex, loTransaction, llSuccess

      * First commit log data
      This.CommitLog()

      * Then commit transaction
      lnCollectionIndex = This.GetTransactionIndex(Txnlevel())
      If !Empty(m.lnCollectionIndex)
         loTransaction = This.GetTransactionByCollectionIndex(m.lnCollectionIndex)

         loTransaction.lRollback = .F.
         This.oTransactionManagers.Remove(m.lnCollectionIndex)
         loTransaction = .Null.
         Release m.loTransaction

         llSuccess = .T.
      Endif

      Return m.llSuccess
   Endproc

   Procedure RollbackTransaction()
      * Rollback
      Local lnCollectionIndex, loTransaction, llSuccess

      * First commit log data
      * yes, seriously, I want to partly keep whats not participating in the current transaction
      This.CommitLog()

      lnCollectionIndex = This.GetTransactionIndex(Txnlevel())
      If !Empty(m.lnCollectionIndex)
         loTransaction = This.GetTransactionByCollectionIndex(m.lnCollectionIndex)

         loTransaction.lRollback = .T.
         This.oTransactionManagers.Remove(m.lnCollectionIndex)
         loTransaction = .Null.
         Release m.loTransaction

         This.cLogDir = Sys(2015) + '_' + This.cBaseDir

         llSuccess = .T.
      Endif

      Return m.llSuccess
   Endproc

   Procedure CommitLog()
      * Store all buffered data
      Local lnCount, lnWorkarea
      Local Array laWorkareas[1]

      For lnCount=1 To Aused(m.laWorkareas)
         lnWorkarea = m.laWorkareas[m.lnCount,2]
         If CursorGetProp('Buffering', m.lnWorkarea) = 5 && Table buffered
            If Not Getnextmodified(0,m.lnWorkarea,.F.) = 0
               =Tableupdate(2, .T., m.lnWorkarea)
               #If DEBUGMODE
               Else
                  Debugout 'Nothing new from SessionManager Commit'
               #Endif
            Endif
         Endif
      Endfor

      Local loSessionLogger
      Try
         loSessionLogger = This.oSessionLogger
      Catch
         *
      Endtry
      If Vartype(loSessionLogger)='O'
         * run the commit itself outside Try..catch
         * better for debugging
         loSessionLogger.CommitLog()
      Endif
   Endproc

   Procedure Destroy()
      * Last log data commit
      This.CommitLog()

      * Then commit any open transactions
      Try
         Do While Txnlevel()>0 And This.CommitTransaction()
            DoEvents
         Enddo
      Catch
         *
      Endtry

      This.cLogDir = 'endsession'
   Endproc

Enddefine

Define Class SessionLogger As DataLogger
   Abstract                 = .F.
   DataSession              =  2 && 'private' logging is done in a separate datatsession
   iForSessionId            =  0
   iInitialTransactionLevel =  0
   lLogRecord               = .F.
   lUseTableSignature       = .F.
   cLogTablenameExpr        = '"none"'
   cMetaTablenameExpr       = '"SessionMeta"'
   nBuffering               = 5 && optimistic table buffering

   Procedure Init()
      Lparameters tiForSessionId, tiInitialTransactionLevel
      This.iForSessionId            = tiForSessionId
      This.iInitialTransactionLevel = tiInitialTransactionLevel

      Local llInstanciate
      llInstanciate = DoDefault()

      If llInstanciate
         Set Multilocks On
         * To use transactions buffering is optional, but I wants to log as fast as possible,
         * writing only what needs to be written (is commited) to disk

         * This delays writing of log data for the not unusual case developers
         * write multiole RREPLACE field WITH value and thus trigger update multiple times
         * writing to disc should ideally be done just in time, when a transaction ends and is commited.
         * So rollbacks have least work to do.

         * Compromise: this manager will fire up a timer to persist log data from time to time.
         * The timer will reset itself before its interval is reached, when many triggers fire in short sequence
         * so saving will be delayed then ideally to save less condensed log entries.

         This.cLogDir = '_s'+ Transform(m.tiForSessionId) + This.cBaseDir
      Endif

      Return llInstanciate
   Endproc

   Procedure cLogDir_Assign()
      Lparameters tvNewValue
      Local lcLogDBC, lcLogPath, liLogId

      lcLogDBC = This.cLogDBC
      If !Empty(m.lcLogDBC)
         Try
            Set Database To (m.lcLogDBC)
            If Lower(Set('Database'))==Lower(Juststem(m.lcLogDBC))
               This.CommitLog()
               Close Database
            Endif
         Catch
            *
         Endtry
      Endif

      This.cLogDir = m.tvNewValue

      If m.tvNewValue <> 'endsessionlog'
         liLogId = _vfp.Transactions.LogId()

         lcLogPath = This.cLogPath
         This.cLogDBC = Addbs(m.lcLogPath)+'sessions\logid_'+Transform(m.liLogId)+This.cLogDir+'\sessionlog.dbc'
         This.CheckDir()

         Local loLogInfo
         loLogInfo = Createobject('empty')
         * LogInfo
         AddProperty(m.loLogInfo, 'cLogType'          , 's'                              ) && Session
         AddProperty(m.loLogInfo, 'iLogId'            , m.liLogId                        )
         AddProperty(m.loLogInfo, 'iTransactionLogId' , 0                                )
         AddProperty(m.loLogInfo, 'lLogRecord'        , .F.                              )
         AddProperty(m.loLogInfo, 'tLogTime'          , Datetime()                       )
         AddProperty(m.loLogInfo, 'iLogStatus'        , LOGSTATUSINFOCREATED             )
         AddProperty(m.loLogInfo, 'iDatasessionId'    , This.iForSessionId               )
         AddProperty(m.loLogInfo, 'iTransactionLevel' , This.iInitialTransactionLevel    )
         AddProperty(m.loLogInfo, 'mLogDir'           , Justpath(This.cLogDBC)           )
         AddProperty(m.loLogInfo, 'mDBC'              , This.cLogDBC                     )
         AddProperty(m.loLogInfo, 'cLogTablenameExpr' , '"norecordforsessions"'          )
         AddProperty(m.loLogInfo, 'cMetaTablenameExpr', '"Sessions"'                     )
         AddProperty(m.loLogInfo, 'mCaller'           , Sys(16,Max(0,Program(-1)-1))+Id())

         _vfp.TransactionLogQueue.Queue(m.loLogInfo, .T.)
      Endif
   Endproc

   Procedure CommitLog()
      * Store all buffered data
      Local lnCount, lnWorkarea
      Local Array laWorkareas[1]

      For lnCount=1 To Aused(m.laWorkareas)
         lnWorkarea = m.laWorkareas[m.lnCount,2]
         If CursorGetProp('Buffering', m.lnWorkarea) = 5 && Table buffered
            If Not Getnextmodified(0, m.lnWorkarea,.F.) = 0
               =Tableupdate(2, .T., m.lnWorkarea)
               #If DEBUGMODE
               Else
                  Debugout 'Nothing new from SessionLogger Commit'
               #Endif
            Endif
         Endif
      Endfor
   Endproc

   Procedure Destroy()
      * Last commit in current transaction
      * final saving will be decided by
      * whether transactions default
      * to commit or rollback, but first commit
      * then either it'll persist or be reverted
      This.CommitLog()

      * Then commit any open transactions
      Try
         Do While Txnlevel()>0 And This.CommitTransaction()
            DoEvents
         Enddo
      Catch
         *
      Endtry

      This.cLogDir = 'endsessionlog'
   Endproc

Enddefine

Define Class TransactionManager As Session
   Abstract  = .F.
   lRollback = .T.
   lDontEnd  = .F.
   DataSession = 1 && 'default' datasession, begin/end/rollback transaction in same session, of course

   Procedure Init()
      Lparameters tcLogPath, tlDontBegin

      * For the Case The Session and Transaction already exists before _vfp.Transaction creates a manager for it
      * it won't rollback or commmit what it hasn't begun itself...
      This.lDontEnd = m.tlDontBegin
      If Not m.tlDontBegin
         Begin Transaction
      EndIf
      
      AddProperty(This, 'oTransactionLogger', Createobject('TransactionLogger', tcLogPath, Set("Datasession"), Txnlevel()))
   Endproc

   Procedure Log()
      Lparameters toLogInfo
      Return This.oTransactionLogger.Log(m.toLogInfo)
   Endproc

   Procedure Destroy()
      * Last commit in logger
      Local liTransactionLogId
      If PemStatus(This,'oTransactionLogger',5) And Vartype(This.oTransactionLogger)='O'
         liTransactionLogId = This.oTransactionLogger.iTransactionLogId
      
         This.oTransactionLogger = .NULL.
         RemoveProperty(This, 'oTransactionLogger')
      Else 
         liTransactionLogId = -1
      EndIf 

      If Not This.lDontEnd And Txnlevel()>0
         If This.lRollback
            Rollback
         Else
            End Transaction
         Endif
      EndIf
      
      If liTransactionLogId >0
         * Log ststus update for liTransactionLogId = This.oTransactionLogger.iTransactionLogId
         Update transactionlog!alltransactionevents ;
            Set iLogStatus = Iif(This.lRollback, LOGSTATUSTRANSACTIONROLLEDBACK, LOGSTATUSTRANSACTIONCOMMITTED) ;
            Where iTransactionLogId = m.liTransactionLogId
      EndIf 
   Endproc
Enddefine

Define Class TransactionLogger As DataLogger
   Abstract  = .F.
   lRollback = .T.
   DataSession = 2 && 'private' datasession, logging in separate session than transaction
   iForSessionId = -1
   iForTransactionLevel = -1
   iTransactionLogId = 0

   Procedure Init()
      Lparameters tcLogPath, tnForSessionId, tnForTransactionLevel
      Local llInstanciate
      llInstanciate = DoDefault()

      If llInstanciate
         This.iForSessionId = m.tnForSessionId
         This.iForTransactionLevel = m.tnForTransactionLevel
         Set Exclusive Off
         Set Multilocks On

         This.cLogPath = tcLogPath
         This.cLogDir  = '_s'+ Transform(m.tnForSessionId) + '_t' + Transform(m.tnForTransactionLevel)
      Endif

      Return llInstanciate
   Endproc

   Procedure cLogDir_Assign()
      Lparameters tvNewValue
      Local lcLogDBC, lcLogPath, liLogId

      lcLogDBC = This.cLogDBC
      If !Empty(m.lcLogDBC)
         Try
            Set Database To (m.lcLogDBC)
            If Lower(Set('Database'))==Lower(Juststem(m.lcLogDBC))
               This.CommitLog()
               Close Database
            Endif
         Catch
            *
         Endtry
      Endif

      This.cLogDir = m.tvNewValue
      This.iTransactionLogId = _vfp.Transactions.LogId()
      * This.oTransactionManager.iTransactionLogId

      lcLogPath = This.cLogPath
      This.cLogDBC = Addbs(m.lcLogPath)+'logid_'+Transform(This.iTransactionLogId)+This.cLogDir+'\logdetails.dbc'
      This.CheckDir()

      Local loLogInfo
      loLogInfo = Createobject('empty')
      * LogInfo
      AddProperty(m.loLogInfo, 'cLogType'          , 't'                              ) && Transaction
      AddProperty(m.loLogInfo, 'iLogId'            , This.iTransactionLogId           )
      AddProperty(m.loLogInfo, 'iTransactionLogId' , This.iTransactionLogId           )
      AddProperty(m.loLogInfo, 'lLogRecord'        , .F.                              )
      AddProperty(m.loLogInfo, 'tLogTime'          , Datetime()                       )
      AddProperty(m.loLogInfo, 'iDatasessionId'    , This.iForSessionId               )
      AddProperty(m.loLogInfo, 'iTransactionLevel' , This.iForTransactionLevel        )
      AddProperty(m.loLogInfo, 'iLogStatus'        , LOGSTATUSINFOCREATED             )
      AddProperty(m.loLogInfo, 'mLogDir'           , Justpath(This.cLogDBC)           )
      AddProperty(m.loLogInfo, 'mDBC'              , This.cLogDBC                     )
      AddProperty(m.loLogInfo, 'cLogTablenameExpr' , '"norecordfortransaction"'       )
      AddProperty(m.loLogInfo, 'cMetaTablenameExpr', '"Transactions"'                 )
      AddProperty(m.loLogInfo, 'mCaller'           , Sys(16,Max(0,Program(-1)-1))+Id())

      _vfp.TransactionLogQueue.Queue(m.loLogInfo,.T.)
   Endproc

   Procedure Log()
      Lparameters toLogInfo
      toLogInfo.iTransactionLogId = This.iTransactionLogId
      Return DoDefault(m.toLogInfo)
   Endproc

   Procedure CommitLog()
      * Store all buffered data
      Local lnCount, lnWorkarea
      Local Array laWorkareas[1]

      For lnCount=1 To Aused(m.laWorkareas)
         lnWorkarea = m.laWorkareas[m.lnCount,2]
         If CursorGetProp('Buffering', m.lnWorkarea) = 5 && Table buffered
            If Not Getnextmodified(0, m.lnWorkarea,.F.) = 0
               =Tableupdate(2, .T., m.lnWorkarea)
               #If DEBUGMODE
               Else
                  Debugout 'Nothing new from TransactionLogger Commit'
               #Endif
            Endif
         Endif
      Endfor
   Endproc

   Procedure Destroy()
      #If DEBUGMODE
         Debugout 'TransactionLogger calls LogQueue FinishTransaction for Session,Transaction ', This.iForSessionId, This.iForTransactionLevel
      #Endif
      If Pemstatus(_vfp,"TransactionLogQueue",5) And Vartype(_vfp.TransactionLogQueue)="O"
         _vfp.TransactionLogQueue.FinishTransaction(This.iForSessionId, This.iForTransactionLevel , This)
         * otherwise this would be meshed into
         * another transaction of the same session.

         * Last commit in current transaction
         * final saving will be decided by
         * whether transactions default
         * to commit or rollback, but first commit
         * then either it'll persist or be reverted
         This.CommitLog()
      Endif

      Try
         Close Tables All
         Set Database To logdetails
         Close Database
      Catch
         *
      Endtry

   Endproc
Enddefine

Define Class EasyCollection As Collection

   Procedure Pile()
      Lparameters tvItem, tcKey

      This.Add(m.tvItem, m.tcKey)
   Endproc

   Procedure Peek()
      Lparameters tvIndexOrKey
      Local lnIndex, lvItem

      If Vartype(m.tvIndexOrKey)="C"
         lnIndex = This.GetKey(m.tvIndexOrKey)
      Else
         lnIndex = Evl(m.tvIndexOrKey, This.Count)
      Endif

      If m.lnIndex>0 And m.lnIndex<= This.Count
         lvItem = This.Item(m.lnIndex)
      Else
         lvItem = .Null.
      Endif

      Return m.lvItem
   Endproc

   Procedure Dump()
      Lparameters tvIndexOrKey
      Local lnIndex

      If Vartype(m.tvIndexOrKey)="C"
         lnIndex = This.GetKey(m.tvIndexOrKey)
      Else
         lnIndex = Evl(m.tvIndexOrKey, This.Count)
      Endif

      If m.lnIndex>0 And m.lnIndex<= This.Count
         This.Remove(m.lnIndex)
      Endif
   Endproc
Enddefine

Define Class EasyQueue       As EasyCollection

   Procedure Queue(vItem)
      #If DEBUGMODE
         Debugout 'Queue() operation, size before', This.Count
      #Endif

      This.Pile(vItem,Str(vItem.iLogId))

      #If DEBUGMODE
         Debugout 'Queue() operation, size after', This.Count
      #Endif
   Endproc

   Procedure DeQueue()
      Local lvItem

      #If DEBUGMODE
         Debugout 'DeQueue() operation, size before', This.Count
      #Endif

      If This.Count>0
         lvItem = This.Peek(1)
         This.Dump(1)
      Else
         lvItem = .Null.
      Endif

      #If DEBUGMODE
         Debugout 'DeQueue() operation, size after', This.Count
      #Endif

      Return m.lvItem
   Endproc

   Procedure PeekQueue()
      Lparameters tvIndexOrKey

      #If DEBUGMODE
         Debugout 'Peek() operation, size before', This.Count
      #Endif

      Local lvItem

      If This.Count>0
         lvItem = This.Peek(tvIndexOrKey)
      Else
         lvItem = .Null.
      Endif

      #If DEBUGMODE
         Debugout 'Peek() operation, size after', This.Count
      #Endif

      Return m.lvItem
   Endproc

   Procedure UnQueue()
      Lparameters tvIndexOrKey
      Local llDumped

      #If DEBUGMODE
         Debugout 'UnQueue() operation, size before', This.Count
      #Endif

      tvIndexOrKey = Evl(m.tvIndexOrKey,1)
      If This.Count>0
         This.Dump(m.tvIndexOrKey)
         llDumped = .T.
      Endif

      #If DEBUGMODE
         Debugout 'UnQueue() operation, size after', This.Count
      #Endif

      Return llDumped
   Endproc
Enddefine

Define Class LogQueue As EasyQueue

   Procedure Queue()
      Lparameters toLogInfo, tlNoHeadlog, llSuccess
      Try
         If m.toLogInfo.iLogId = 0
            toLogInfo.iLogId = _vfp.Transactions.LogId()
         Endif
         #If DEBUGMODE
            Debugout 'queue time for '+Str(m.toLogInfo.iLogId)+' was', Seconds()
         #Endif
         This.Pile(m.toLogInfo, Str(m.toLogInfo.iLogId))
         * notice at this stage the queue knows the log object, no matter what happens next
         m.toLogInfo.iLogStatus = LOGSTATUSQUEUED

         If Not tlNoHeadlog
            If _vfp.Transactions.Log(m.toLogInfo, .T.)
               If Not m.toLogInfo.lLogRecord
                  This.Dump(Str(m.toLogInfo.iLogId))
               Else
                  m.toLogInfo.iLogStatus = LOGSTATUSHEADDATARECORDED
               EndIf 
            EndIf
         Endif
         * LOGSTATUSLOGGED, persisted storage of all vItem properties including the oRecord
         * will be achieved by _VFP.LogTimer.

         * As we speak if it...
         * Reset log timer, so many log events queue for a single pass of writing
         Try
            _vfp.TransactionLogTimer.Reset()
            _vfp.TransactionLogTimer.Enabled = .T.
         Catch
            *
         Endtry

      Catch
         *
      Endtry
   Endproc

   Procedure Log()
      Local loLogInfo, ltTimeout, lnItemIndex, lnLastCount
      ltTimeout = Datetime()+1
      * work for maximum 1 second

      lnLastCount = This.Count+1
      Do While This.Count > 0 And This.Count < m.lnLastCount And Datetime()<ltTimeout
         lnLastCount = This.Count
         lnItemIndex = 1 && process queue from 1 to count
         Do While This.Count>0 And Datetime()<ltTimeout
            loLogInfo = This.PeekQueue(m.lnItemIndex)

            If !Isnull(m.loLogInfo)
               #If DEBUGMODE
                  Debugout 'Process LogId', m.loLogInfo.iLogId
               #Endif
               * LOGSTATUSHEADDATARECORDED (2) -> LOGSTATUSLOGGED (3)
               If m.loLogInfo.iLogStatus = LOGSTATUSHEADDATARECORDED
                  #If DEBUGMODE
                     Debugout 'log details'
                  #Endif
                  If _vfp.Transactions.Log(m.loLogInfo)
                     m.loLogInfo.iLogStatus=LOGSTATUSLOGGED
                  Endif
                  * remove from queue as it now IS processed
                  * (but in case of a crash of _VFP.Transactions,
                  * keep the Queue intact)
                  #If DEBUGMODE
                     Debugout 'unqueue time for '+Str(m.loLogInfo.iLogId)+' was', Seconds()
                  #Endif
                  If Not This.UnQueue(Str(m.loLogInfo.iLogId))
                     #If DEBUGMODE
                        Debugout "unqueue for "+Str(m.loLogInfo.iLogId)+" didn't work"
                     #Endif
                  Endif
               Endif

               * LOGSTATUSQUEUED (1) -> LOGSTATUSHEADDATARECORDED (2)
               If m.loLogInfo.iLogStatus=LOGSTATUSQUEUED
                  #If DEBUGMODE
                     Debugout 'log details'
                  #Endif
                  If _vfp.Transactions.Log(m.loLogInfo, .T.)
                     m.loLogInfo.iLogStatus=LOGSTATUSHEADDATARECORDED
                  Endif
                  lnItemIndex = m.lnItemIndex + 1
               Endif
            Else
               lnItemIndex = m.lnItemIndex + 1
            Endif

            If m.lnItemIndex > This.Count
               Exit
            Endif
         Enddo
      Enddo
   Endproc

   Procedure FinishTransaction()
      Lparameters tnInSessionId, tnTransaction, toLogger
      * Process all log info from that sessions transaction (it's about to finish)

      #If DEBUGMODE
         Debugout 'Finish Transaction starts with Item Count', This.Count
      #Endif

      Local loLogInfo, ltTimeout, lnItemIndex
      ltTimeout = Datetime()+30 && long, but still a timeout

      lnItemIndex = 1 && process queue from 1 to count
      Do While This.Count>0 And Datetime()<m.ltTimeout
         loLogInfo = This.Peek(m.lnItemIndex)

         If !Isnull( loLogInfo) And ;
               (m.loLogInfo.iDataSessionId   = m.tnInSessionId  And ;
               M.loLogInfo.iTransactionLevel = m.tnTransaction)

            #If DEBUGMODE
               Debugout 'Process LogId', m.loLogInfo.iLogId
            #Endif

            If m.loLogInfo.iLogStatus<LOGSTATUSLOGGED
               If m.toLogger.Log(m.loLogInfo)
                  m.loLogInfo.iLogStatus=LOGSTATUSLOGGED
               EndIf
            Endif

            If m.loLogInfo.iLogStatus=LOGSTATUSLOGGED And This.UnQueue(Str(m.loLogInfo.iLogId))
               #If DEBUGMODE
                  Debugout 'unqueue time for '+Str(m.loLogInfo.iLogId)+' was', Seconds()
               #Endif
               * This reduces count by 1 and the same
               * lnItemIndex points to the next or previous Item
               * Anyway, we'll get to the next valid one
               * with the loop
            Else
               #If DEBUGMODE
                  Debugout "unqueue for "+Str(m.loLogInfo.iLogId)+" didn't work"
               #Endif
               * Diffcult item? Dkip it
               * should never happen, but to make sure
               * we progress through items:
               lnItemIndex = lnItemIndex + 1
            Endif
         Else
            * none of our business, skip it
            lnItemIndex = lnItemIndex + 1
         Endif

         If lnItemIndex > This.Count
            Exit
         Endif
      Enddo

      #If DEBUGMODE
         Debugout 'Finish Transaction ends with Item Count', This.Count
      #Endif

   Endproc
Enddefine

Define Class LogTimer As Timer
   Interval = 1000
   Enabled = .F.

   Procedure Timer()
      This.Enabled = .F.
      This.Reset()

      Local llContinue, llReconstruct, loException

      Try
         _vfp.Transactions.CommitLog()
      Catch To loException When Inlist(m.loException.ErrorNo, 1734, 1925)
         llReconstruct = .T.
      Endtry

      If Not llReconstruct
         Try
            #If DEBUGMODE
               Debugout 'Log timer'
            #Endif
            _vfp.TransactionLogQueue.Log()
            If _vfp.TransactionLogQueue.Count>0
               llContinue = .T.
               #If DEBUGMODE
                  Debugout 'continue with', _vfp.TransactionLogQueue.Count
               #Endif
            Else
               #If DEBUGMODE
                  Debugout 'LogTimer goes to sleep - LogQueue will reactivate with new queued loginfo.'
               #Endif
            Endif
            #If DEBUGMODE
               Debugout '------------------------------------------------------'
            #Endif
         Catch To loException When Inlist(m.loException.ErrorNo, 1734, 1925)
            llReconstruct = .T.
         Finally
            This.Enabled = m.llContinue And Not m.llReconstruct
         Endtry
      Endif

      If m.llReconstruct
         If Pemstatus(_vfp,"Transactions",5)
            If Isnull(_vfp.Transactions)
               * likely normal end of the application session,
               * release rest of the system, too
               m.llReconstruct  = .F.
            Endif

            Try
               * release the system
               _vfp.Transactions.Release()
            Catch
               *
            Endtry

            Try
               _vfp.TransactionLogTimer = .Null.
               Removeproperty(_vfp,"TransactionLogTimer")
               _vfp.TransactionLogQueue = .Null.
               Removeproperty(_vfp,"TransactionLogQueue")
               _vfp.Transactions = .Null.
               Removeproperty(_vfp,"Transactions")
            Catch
               *
            Endtry

            If m.llReconstruct
               * revive it
               _vfp.Transactions = Createobject('TransactionLogManager')
            Endif
         Endif
      Endif

   Endproc
Enddefine

Define Class QuitTimer As Timer
   Interval = 60
   Enabled = .T.

   Procedure Timer()
      This.Enabled = .F.
      Quit
   Endproc
Enddefine

Procedure dbcCreateObject()
   Lparameters tcClass
   Return Createobject(m.tcClass)
Endproc

*****************************
*      Do not remove!       *
*   This marks the end of   *
*   VFPTransactions stored  *
*   procedures.             *
***  VFPTransactions END  ***
