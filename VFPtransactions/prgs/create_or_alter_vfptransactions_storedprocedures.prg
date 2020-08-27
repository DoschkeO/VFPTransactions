Lparameters tcDBC

Local lcDBC
If Pcount()>0
   lcDBC = m.tcDBC
Else
   lcDBC = Dbc()
EndIf

Local llSuccess
Local lcDBC, lcDBCProcsFile, lcDBCProcs
Local lcVFPTransactionslogProcsFile, lcVFPTransactionslogProcs
llSuccess = .T. && assume suucess until failure

If Pcount()>0
   Try
      Open Database (m.lcDBC) Exclusive
   Catch
      llSuccess = .F.
      Error "Can't get exclusve access, please close DBC in all Foxpro sessions and/or clients before proeeding."
   Endtry

   If Not Dbused(m.lcDBC)
      Error "Can't open database for some reason. If you already open it yourself make the call without passing in the DBC file."
      Return .F.
   EndIf
   
   Set Database To (m.lcDBC)
EndIf

If Empty(Set('Database'))
   Error "No database is currently set to process with VFPTransaction procedures."
   Return .F.
EndIf
 
If Not IsExclusive(Set("Database"),2)
   Error "The database has to be open exclusive. I can't establish VFPTransaction procedures in a database only open in shared mode."
   Return .F.
EndIf

lcVFPTransactionslogProcsFile = 'vfptransactions_storedprocedures.prg'
If _vfp.StartMode =0
   Local loProject, loProfjectFile
   For Each loProject in _vfp.Projects
       * look for VFptransactions.pjx
       If Lower(JustStem(loProject.Name))=="vfptransactions"
          For Each loProjectFile in m.loProject.Files 
              If Lower(JustFname(m.loProjectFile.Name)) == m.lcVFPTransactionslogProcsFile
                 lcVFPTransactionslogProcsFile = m.loProjectFile.Name
              EndIf 
          EndFor
       EndIf 
   EndFor 
Else
   lcVFPTransactionslogProcsFile = JustPath(Program())+m.lcVFPTransactionslogProcsFile
   Local Array laDir[1]
   
   If ADir(laDir, m.VFPTransactionslogProcsFile) = 0
      Error lcVFPTransactionslogProcsFile + " not found. Can't create or alter stored procedures without having their PRG file."
   EndIf 
EndIf

lcDBCProcsFile = Addbs(Getenv("TEMP"))+Set("Database")+'_current_storedprocedures'+Sys(2015)+'.txt'
Copy Procedures To (lcDBCProcsFile)
lcDBCProcs = FileToStr(lcDBCProcsFile)
Erase (lcDBCProcsFile)
lcTransactionlogProcs = Filetostr(lcVFPTransactionslogProcsFile)
lnStartpos = At('*** VFPTransactions BEGIN ***', lcDBCProcs)
lnEndpos   = At('***  VFPTransactions END  ***', lcDBCProcs)+Len('***  VFPTransactions END  ***')

If lnStartpos>0 And lnEndpos>0
   * existing VFP Transactions procedures found by header and footer comment lines
   * replace all code ebtween these positions with current procedures:
   lcDBCProcs = Stuff(lcDBCProcs, lnStartpos, lnEndpos-lnStartpos, lcTransactionlogProcs)
   Strtofile(lcDBCProcs, lcDBCProcsFile, .F.)
   Append Procedures From (lcDBCProcsFile) Overwrite
Else
   lcDBCProcs = lcTransactionlogProcs+CHR(13)+CHR(10)+lcDBCProcs
   Strtofile(lcDBCProcs, lcDBCProcsFile, .F.)
   Append Procedures From (lcDBCProcsFile) Overwrite
EndIf
Pack DATABASE 
Erase (lcDBCProcsFile)
Compile Database (lcDBC)

Local lcOldSafety, lnCount, lcInsertTrigger, lcUpdateTrigger, lcDeleteTrigger

lcOldSafety = Set("Safety")
Set Safety Off

For lnCount = 1 To Adbobjects(laDBFs,"TABLE")
   lcDBF = laDBFs[lnCount]
   lcInsertTrigger = DBGetProp(lcDBF,'TABLE','InsertTrigger')

   If Not 'vfplog(logrecord("i"),' $ lcInsertTrigger
      If Empty(m.lcInsertTrigger)
         lcInsertTrigger = 'vfplog(logrecord("i"), .T.)'
      Else
         lcInsertTrigger = Textmerge('vfplog(logrecord("i"), <<m.lcInsertTrigger>>)')
      Endif
      Create Trigger On (lcDBF) For Insert As &lcInsertTrigger
   Endif

   lcUpdateTrigger = DBGetProp(lcDBF,'TABLE','UpdateTrigger')
   If Not 'vfplog(logrecord("u"),' $ lcUpdateTrigger
      If Empty(m.lcUpdateTrigger)
         lcUpdateTrigger = 'vfplog(logrecord("u"), .T.)'
      Else
         lcUpdateTrigger = Textmerge('vfplog(logrecord("u"), <<m.lcUpdateTrigger>>)')
      Endif
      Create Trigger On (lcDBF) For Update As &lcUpdateTrigger
   Endif

   lcDeleteTrigger = DBGetProp(lcDBF,'TABLE','DeleteTrigger')
   If Not 'vfplog(logrecord("d"),' $ lcDeleteTrigger
      If Empty(m.lcDeleteTrigger)
         lcDeleteTrigger = 'vfplog(logrecord("d"), .T.)'
      Else
         lcDeleteTrigger = Textmerge('vfplog(logrecord("d"), <<m.lcDeleteTrigger>>)')
      Endif
      Create Trigger On (lcDBF) For Delete As &lcDeleteTrigger
   Endif
Endfor

Pack DATABASE 
Set Safety &lcOldSafety