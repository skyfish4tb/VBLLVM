VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
  Persistable = 0  'NotPersistable
  DataBindingBehavior = 0  'vbNone
  DataSourceBehavior  = 0  'vbNone
  MTSTransactionMode  = 0  'NotAnMTSObject
END
Attribute VB_Name = "cCodegen"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'=========================================================================
'
' VBLLVM Project
' kscope (c) 2018 by wqweto@gmail.com
'
' Kaleidoscope toy language for VBLLVM
'
' cCodegen.cls - Codegen functions
'
'=========================================================================
Option Explicit
DefObj A-Z

Private m_sLastError        As String
Private m_oTree             As Object
Private m_sModuleName       As String
Private m_hModule           As LLVMModuleRef
Private m_hBuilder          As LLVMBuilderRef
Private m_oModuleScope      As Scripting.Dictionary
Private m_oLocalScope       As Scripting.Dictionary

'=========================================================================
' Properties
'=========================================================================

Property Get LastError() As String
    LastError = m_sLastError
End Property

'=========================================================================
' Methods
'=========================================================================

Public Function Init(oTree As Object, sModuleName As String) As Boolean
    Set m_oTree = oTree
    m_sModuleName = sModuleName
    Set m_oModuleScope = New Scripting.Dictionary
    Set m_oLocalScope = m_oLocalScope
    m_hModule = LLVMModuleCreateWithName(m_sModuleName)
    If m_hModule = 0 Then
        GoTo QH
    End If
    m_hBuilder = LLVMCreateBuilder()
    If m_hBuilder = 0 Then
        GoTo QH
    End If
    '--- success
    Init = True
QH:
End Function

Public Function CodeGenTop(vNode As Variant) As Boolean
    Dim oFunc           As Object
    Dim oProto          As Object
    
    Select Case JsonItem(C_Obj(vNode), "Tag")
    Case "Def", "Extern"
        CodeGenTop = CodeGenNode(vNode, 0)
    Case Else
        JsonItem(oProto, "Tag") = "Prototype"
        JsonItem(oProto, "Name") = "__anon_expr"
        JsonItem(oFunc, "Tag") = "Def"
        JsonItem(oFunc, "Proto") = oProto
        JsonItem(oFunc, "Body") = vNode
        CodeGenTop = CodeGenNode(oFunc, 0)
    End Select
End Function

Public Function CodeGenNode(vNode As Variant, hResult As LLVMValueRef) As Boolean
    Dim oNode           As Scripting.Dictionary
    
    Select Case VarType(vNode)
    Case vbDouble
        hResult = LLVMConstReal(LLVMDoubleType(), vNode)
    Case vbString
        hResult = pvScopeResolve(m_oLocalScope, C_Str(vNode))
        If hResult = 0 Then
            m_sLastError = "Undefined '" & vNode & "'"
            GoTo QH
        End If
    Case vbObject
        Set oNode = C_Obj(vNode)
        On Error GoTo EH
        If Not CallByName(Me, "Visit" & JsonItem(oNode, "Tag"), VbMethod, oNode, hResult) Then
            GoTo QH
        End If
        On Error GoTo 0
    Case Else
        Err.Raise vbObjectError, , "Unknown node vartype: " & VarType(vNode)
    End Select
    '--- success
    CodeGenNode = True
QH:
    Exit Function
EH:
    If Err.Number = 438 Then ' Object doesn't support this property or method
        Err.Raise vbObjectError, , "Unknown node type: " & JsonItem(oNode, "Tag")
    End If
    Err.Raise Err.Number, Err.Source, Err.Description
End Function

Public Function VisitDef(oNode As Scripting.Dictionary, hResult As LLVMValueRef) As Boolean
    Dim oScope          As Scripting.Dictionary
    Dim hBlock          As LLVMBasicBlockRef
    Dim hBody           As LLVMValueRef

    Set oScope = New Scripting.Dictionary
    pvScopePush oScope
    If Not CodeGenNode(JsonItem(oNode, "Proto"), hResult) Then
        GoTo QH
    End If
    hBlock = LLVMAppendBasicBlock(hResult, "entry")
    Call LLVMPositionBuilderAtEnd(m_hBuilder, hBlock)
    If Not CodeGenNode(JsonItem(oNode, "Body"), hBody) Then
        Call LLVMDeleteFunction(hResult)
        GoTo QH
    End If
    Call LLVMBuildRet(m_hBuilder, hBody)
    If LLVMVerifyFunction(hResult, LLVMPrintMessageAction) = 1 Then
        Call LLVMDeleteFunction(hResult)
        GoTo QH
    End If
    '--- success
    VisitDef = True
QH:
    If Not oScope Is Nothing Then
        pvScopePop
    End If
End Function

Public Function VisitPrototype(oNode As Scripting.Dictionary, hResult As LLVMValueRef) As Boolean
    Dim lCount          As Long
    Dim aParams()       As LLVMTypeRef
    Dim lIdx            As Long
    Dim hType           As LLVMTypeRef
    Dim hParam          As LLVMValueRef
    
    If IsObject(JsonItem(oNode, "Params")) Then
        lCount = UBound(JsonKeys(oNode, "Params")) + 1
    End If
    hResult = LLVMGetNamedFunction(m_hModule, JsonItem(oNode, "Name"))
    If hResult <> 0 Then
        If LLVMCountParams(hResult) <> lCount Then
            m_sLastError = JsonItem(oNode, "Name") & " declared with different param count"
            GoTo QH
        End If
        If LLVMCountBasicBlocks(hResult) <> 0 Then
            m_sLastError = JsonItem(oNode, "Name") & " already defined"
            GoTo QH
        End If
    Else
        ReDim aParams(0 To lCount) As LLVMTypeRef '--- one more
        For lIdx = 0 To lCount - 1
            aParams(lIdx) = LLVMDoubleType()
        Next
        hType = LLVMFunctionType(LLVMDoubleType(), aParams(0), lCount, 0)
        Debug.Assert hType <> 0
        hResult = LLVMAddFunction(m_hModule, JsonItem(oNode, "Name"), hType)
        m_oModuleScope.Item(JsonItem(oNode, "Name")) = hResult
    End If
    For lIdx = 0 To lCount - 1
        hParam = LLVMGetParam(hResult, lIdx)
        Debug.Assert hParam <> 0
        Call LLVMSetValueName(hParam, JsonItem(oNode, "Params/" & lIdx))
        m_oLocalScope.Item(JsonItem(oNode, "Params/" & lIdx)) = hParam
    Next
    '--- success
    VisitPrototype = True
QH:
End Function

Public Function VisitBinExpr(oNode As Scripting.Dictionary, hResult As LLVMValueRef) As Boolean
    Dim hLeft           As LLVMValueRef
    Dim hRight          As LLVMValueRef
    Dim aArgs()         As LLVMValueRef
    
    If Not CodeGenNode(JsonItem(oNode, "Left"), hLeft) Then
        GoTo QH
    End If
    If Not CodeGenNode(JsonItem(oNode, "Right"), hRight) Then
        GoTo QH
    End If
    Select Case JsonItem(oNode, "Oper")
    Case "+"
        hResult = LLVMBuildFAdd(m_hBuilder, hLeft, hRight, "addtmp")
    Case "-"
        hResult = LLVMBuildFSub(m_hBuilder, hLeft, hRight, "subtmp")
    Case "*"
        hResult = LLVMBuildFMul(m_hBuilder, hLeft, hRight, "multmp")
    Case "/"
        hResult = LLVMBuildFDiv(m_hBuilder, hLeft, hRight, "divtmp")
    Case "<"
        hResult = LLVMBuildFCmp(m_hBuilder, LLVMRealULT, hLeft, hRight, "cmptmp")
        hResult = LLVMBuildCast(m_hBuilder, LLVMUIToFP, hResult, LLVMDoubleType(), "booltmp")
    Case Else
        hResult = GetFunction("binary" & JsonItem(oNode, "Oper"))
        If hResult = 0 Then
            m_sLastError = "Unknown binop '" & JsonItem(oNode, "Oper") & "'"
            GoTo QH
        End If
        ReDim aArgs(0 To 1) As LLVMValueRef
        aArgs(0) = hLeft
        aArgs(1) = hRight
        hResult = LLVMBuildCall(m_hBuilder, hResult, aArgs(0), 2, "calltmp")
    End Select
    '--- success
    VisitBinExpr = True
QH:
End Function

Public Function VisitUnExp(oNode As Scripting.Dictionary, hResult As LLVMValueRef) As Boolean
    Dim aArgs()         As LLVMValueRef
    
    hResult = GetFunction("unary" & JsonItem(oNode, "Oper"))
    If hResult = 0 Then
        m_sLastError = "Unknown unary '" & JsonItem(oNode, "Oper") & "'"
        GoTo QH
    End If
    ReDim aArgs(0 To 0) As LLVMValueRef
    If Not CodeGenNode(JsonItem(oNode, "Expr"), aArgs(0)) Then
        GoTo QH
    End If
    hResult = LLVMBuildCall(m_hBuilder, hResult, aArgs(0), 1, "calltmp")
    '--- success
    VisitUnExp = True
QH:
End Function

Public Function VisitCallExpr(oNode As Scripting.Dictionary, hResult As LLVMValueRef) As Boolean
    Dim lCount          As Long
    Dim lIdx            As Long
    Dim aArgs()         As LLVMValueRef
    
    hResult = GetFunction(JsonItem(oNode, "Name"))
    If hResult = 0 Then
        m_sLastError = "Function '" & JsonItem(oNode, "Name") & "' not defined"
        GoTo QH
    End If
    If IsObject(JsonItem(oNode, "Args")) Then
        lCount = UBound(JsonKeys(oNode, "Args")) + 1
    End If
    If LLVMCountParams(hResult) <> lCount Then
        m_sLastError = "Wrong number of arguments to '" & JsonItem(oNode, "Name") & "' function"
        GoTo QH
    End If
    ReDim aArgs(0 To LLVMCountParams(hResult)) As LLVMValueRef
    For lIdx = 0 To lCount - 1
        If Not CodeGenNode(JsonItem(oNode, "Args/" & lIdx), aArgs(lIdx)) Then
            GoTo QH
        End If
    Next
    hResult = LLVMBuildCall(m_hBuilder, hResult, aArgs(0), UBound(aArgs), "calltmp")
    '--- success
    VisitCallExpr = True
QH:
End Function

Public Function VisitIfExpr(oNode As Scripting.Dictionary, hResult As LLVMValueRef) As Boolean
    Dim hCond           As LLVMValueRef
    Dim hThen           As LLVMValueRef
    Dim hElse           As LLVMValueRef
    Dim hFunc           As LLVMValueRef
    Dim hBlockThen      As LLVMBasicBlockRef
    Dim hBlockElse      As LLVMBasicBlockRef
    Dim hBlockMerge     As LLVMBasicBlockRef
    
    If Not CodeGenNode(JsonItem(oNode, "Cond"), hCond) Then
        GoTo QH
    End If
    hFunc = LLVMGetBasicBlockParent(LLVMGetInsertBlock(m_hBuilder))
    hBlockThen = LLVMAppendBasicBlock(hFunc, "then")
    hBlockElse = LLVMAppendBasicBlock(hFunc, "else")
    hBlockMerge = LLVMAppendBasicBlock(hFunc, "ifcont")
    hCond = LLVMBuildFCmp(m_hBuilder, LLVMRealONE, hCond, LLVMConstReal(LLVMDoubleType(), 0), "ifcond")
    Call LLVMBuildCondBr(m_hBuilder, hCond, hBlockThen, hBlockElse)
    Call LLVMPositionBuilderAtEnd(m_hBuilder, hBlockThen)
    If Not CodeGenNode(JsonItem(oNode, "Then"), hThen) Then
        GoTo QH
    End If
    Call LLVMBuildBr(m_hBuilder, hBlockMerge)
    hBlockThen = LLVMGetInsertBlock(m_hBuilder)
    Call LLVMPositionBuilderAtEnd(m_hBuilder, hBlockElse)
    If Not CodeGenNode(JsonItem(oNode, "Else"), hElse) Then
        GoTo QH
    End If
    Call LLVMBuildBr(m_hBuilder, hBlockMerge)
    hBlockElse = LLVMGetInsertBlock(m_hBuilder)
    Call LLVMPositionBuilderAtEnd(m_hBuilder, hBlockMerge)
    hResult = LLVMBuildPhi(m_hBuilder, LLVMDoubleType(), "iftmp")
    Call LLVMAddIncoming(hResult, hThen, hBlockThen, 1)
    Call LLVMAddIncoming(hResult, hElse, hBlockElse, 1)
    '--- success
    VisitIfExpr = True
QH:
End Function

Public Function VisitForExpr(oNode As Scripting.Dictionary, hResult As LLVMValueRef) As Boolean
    Dim hInit           As LLVMValueRef
    Dim hFunc           As LLVMValueRef
    Dim hAlloca         As LLVMValueRef
    Dim hBlockLoop      As LLVMBasicBlockRef
    Dim hStepVal        As LLVMValueRef
    Dim hEnd            As LLVMValueRef
    Dim hCurVar         As LLVMValueRef
    Dim hNextVar        As LLVMValueRef
    Dim hBlockAfter     As LLVMBasicBlockRef
    Dim oScope          As Scripting.Dictionary
    Dim hBody           As LLVMValueRef
    
    If Not CodeGenNode(JsonItem(oNode, "Init"), hInit) Then
        GoTo QH
    End If
    hFunc = LLVMGetBasicBlockParent(LLVMGetInsertBlock(m_hBuilder))
    hAlloca = pvCreateEntryBlockAlloca(hFunc, JsonItem(oNode, "Var"))
    Call LLVMBuildStore(m_hBuilder, hInit, hAlloca)
    hBlockLoop = LLVMAppendBasicBlock(hFunc, "loop")
    Call LLVMBuildBr(m_hBuilder, hBlockLoop)
    Call LLVMPositionBuilderAtEnd(m_hBuilder, hBlockLoop)
    Set oScope = New Scripting.Dictionary
    oScope.Item(JsonItem(oNode, "Var")) = hAlloca
    pvScopePush oScope
    If Not CodeGenNode(JsonItem(oNode, "Body"), hBody) Then
        GoTo QH
    End If
    If Not IsEmpty(JsonItem(oNode, "Step")) Then
        If Not CodeGenNode(JsonItem(oNode, "Step"), hStepVal) Then
            GoTo QH
        End If
    Else
        hStepVal = LLVMConstReal(LLVMDoubleType(), 1)
    End If
    If Not CodeGenNode(JsonItem(oNode, "End"), hEnd) Then
        GoTo QH
    End If
    hEnd = LLVMBuildFCmp(m_hBuilder, LLVMRealONE, hEnd, LLVMConstReal(LLVMDoubleType(), 0), "loopcond")
    hCurVar = LLVMBuildLoad(m_hBuilder, hAlloca, JsonItem(oNode, "Var"))
    hNextVar = LLVMBuildFAdd(m_hBuilder, hCurVar, hStepVal, "nextvar")
    Call LLVMBuildStore(m_hBuilder, hNextVar, hAlloca)
    hBlockAfter = LLVMAppendBasicBlock(hFunc, "afterloop")
    Call LLVMBuildCondBr(m_hBuilder, hEnd, hBlockLoop, hBlockAfter)
    Call LLVMPositionBuilderAtEnd(m_hBuilder, hBlockAfter)
    hResult = LLVMConstReal(LLVMDoubleType(), 0)
    '--- success
    VisitForExpr = True
QH:
    If Not oScope Is Nothing Then
        pvScopePop
    End If
End Function

Public Function VisitVarExpr(oNode As Scripting.Dictionary, hResult As LLVMValueRef) As Boolean
    Dim oScope          As Scripting.Dictionary
    Dim hFunc           As LLVMValueRef
    Dim lIdx            As Long
    Dim hAlloca         As LLVMValueRef
    Dim hInit           As LLVMValueRef
    
    Set oScope = New Scripting.Dictionary
    hFunc = LLVMGetBasicBlockParent(LLVMGetInsertBlock(m_hBuilder))
    For lIdx = 0 To UBound(JsonKeys(oNode, "Vars"))
        hAlloca = pvCreateEntryBlockAlloca(hFunc, JsonItem(oNode, "Vars/" & lIdx & "/Name"))
        If Not IsEmpty(JsonItem(oNode, "Vars/" & lIdx & "/Expr")) Then
            If Not CodeGenNode(JsonItem(oNode, "Vars/" & lIdx & "/Expr"), hInit) Then
                GoTo QH
            End If
            Call LLVMBuildStore(m_hBuilder, hInit, hAlloca)
        End If
        oScope.Item(JsonItem(oNode, "Vars/" & lIdx & "/Name")) = hAlloca
    Next
    pvScopePush oScope
    If Not CodeGenNode(JsonItem(oNode, "Body"), hResult) Then
        GoTo QH
    End If
    '--- success
    VisitVarExpr = True
QH:
    If Not oScope Is Nothing Then
        pvScopePop
    End If
End Function

Private Function pvCreateEntryBlockAlloca(ByVal hFunc As LLVMValueRef, sName As String) As LLVMValueRef
    Dim hBuilder        As LLVMBuilderRef
    Dim hBlock          As LLVMBasicBlockRef
    
    hBuilder = LLVMCreateBuilder()
    hBlock = LLVMGetEntryBasicBlock(hFunc)
    Call LLVMPositionBuilder(hBuilder, hBlock, LLVMGetFirstInstruction(hBlock))
    pvCreateEntryBlockAlloca = LLVMBuildAlloca(hBuilder, LLVMDoubleType(), sName)
End Function

Private Sub pvScopePush(oScope As Scripting.Dictionary)
    Set oScope.Item("#Parent") = m_oLocalScope
    Set m_oLocalScope = oScope
End Sub

Private Sub pvScopePop()
    Set m_oLocalScope = m_oLocalScope.Item("#Parent")
End Sub

Private Function pvScopeResolve(ByVal oScope As Scripting.Dictionary, sName As String) As LLVMValueRef
    Do While Not oScope Is Nothing
        If oScope.Exists(sName) Then
            pvScopeResolve = oScope.Item(sName)
            Exit Do
        End If
        Set oScope = C_Obj(oScope.Item("#Parent"))
    Loop
End Function

Public Function GetModule() As LLVMModuleRef
    Dim lMsgPtr         As Long
    
    If LLVMVerifyModule(m_hModule, LLVMAbortProcessAction, lMsgPtr) <> 0 Then
        m_sLastError = ToString(lMsgPtr)
        Call LLVMDisposeMessage(lMsgPtr)
        GoTo QH
    End If
    GetModule = m_hModule
QH:
End Function

Public Function GetFunction(sName As String) As LLVMValueRef
    'GetFunction = LLVMGetNamedFunction(m_hModule, sName)
    GetFunction = pvScopeResolve(m_oModuleScope, sName)
End Function

Public Function GetIR() As String
    Dim lMsgPtr         As Long
    
    If LLVMVerifyModule(m_hModule, LLVMAbortProcessAction, lMsgPtr) <> 0 Then
        m_sLastError = ToString(lMsgPtr)
        Call LLVMDisposeMessage(lMsgPtr)
        GoTo QH
    End If
    lMsgPtr = LLVMPrintModuleToString(m_hModule)
    If lMsgPtr <> 0 Then
        GetIR = ToString(lMsgPtr)
        Call LLVMDisposeMessage(lMsgPtr)
    End If
QH:
End Function

Public Function EmitToFile(ByVal sFile As String) As Boolean
    Dim hTarget         As Long
    Dim sTriple         As String
    Dim lMsgPtr         As Long
    Dim hMachine        As Long
    
    If LenB(sFile) = 0 Then
        sFile = m_sModuleName & ".o"
    End If
    sTriple = ToString(LLVMGetDefaultTargetTriple())
    If LLVMGetTargetFromTriple(sTriple, hTarget, lMsgPtr) <> 0 Then
        m_sLastError = ToString(lMsgPtr)
        Call LLVMDisposeMessage(lMsgPtr)
        GoTo QH
    End If
    hMachine = LLVMCreateTargetMachine(hTarget, sTriple, vbNullString, vbNullString, _
            LLVMCodeGenLevelAggressive, LLVMRelocDefault, LLVMCodeModelSmall)
    If LLVMTargetMachineEmitToFile(hMachine, m_hModule, sFile, LLVMObjectFile, lMsgPtr) <> 0 Then
        m_sLastError = ToString(lMsgPtr)
        Call LLVMDisposeMessage(lMsgPtr)
        GoTo QH
    End If
    '--- success
    EmitToFile = True
QH:
End Function

'=========================================================================
' Base class events
'=========================================================================

Private Sub Class_Terminate()
    If m_hBuilder <> 0 Then
        Call LLVMDisposeBuilder(m_hBuilder)
    End If
    If m_hModule <> 0 Then
        Call LLVMDisposeModule(m_hModule)
    End If
End Sub