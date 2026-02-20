#Include 'Totvs.ch'
#Include 'Restful.ch'


WSRESTFUL tasks DESCRIPTION "API de Tarefas Morada"

    // Parâmetros de URL (Query Params e Path Params)
    WSDATA page     AS INTEGER OPTIONAL // ?page=1
    WSDATA pageSize AS INTEGER OPTIONAL // ?pageSize=10
    WSDATA idTask   AS STRING  OPTIONAL // /tasks/{idTask}

    // Rotas
    WSMETHOD GET    DESCRIPTION "Listar (Paginado) ou Buscar Um" WSSYNTAX "/tasks/{idTask}"
    WSMETHOD POST   DESCRIPTION "Criar Tarefa"                   WSSYNTAX "/tasks"
    WSMETHOD PUT    DESCRIPTION "Atualizar Tarefa"               WSSYNTAX "/tasks/{idTask}"
    WSMETHOD DELETE DESCRIPTION "Deletar Tarefa"                 WSSYNTAX "/tasks/{idTask}"

END WSRESTFUL

// ==========================================================================
// MÉTODO GET: Listagem Paginada e Busca Unitária
// ==========================================================================
WSMETHOD GET WSRECEIVE idTask, page, pageSize WSREST tasks
    Local oResponse := JsonObject():New()
    Local aTasks    := {}
    Local nP        := If(::page == 0, 1, ::page)         // Default Página 1
    Local nLim      := If(::pageSize == 0, 10, ::pageSize) // Default 10 itens
    Local nSkip     := (nP - 1) * nLim // Cálculo do Offset

    ::SetContentType("application/json")

    // Se veio ID, busca específico (Detalhe)
    If !Empty(::idTask)
        Return ::GetOne(::idTask)
    EndIf

    // Busca Paginada (Lista)
    // Dica de Ouro: Usamos Query Parametrizada para performance
    BeginSQL Alias "TMP"
        SELECT Z2_ID, Z2_TITULO, Z2_STATUS
        FROM %Table:SZ2%
        WHERE %NotDel%
        ORDER BY Z2_ID
    EndSQL

    // Lógica de Paginação (Aplicação)
    // Pula os registros das páginas anteriores
    If nSkip > 0
        TMP->(DbSkip(nSkip))
    EndIf

    // Pega apenas a quantidade do PageSize
    While !TMP->(EOF()) .And. Len(aTasks) < nLim
        aAdd(aTasks, {;
            "id":     TMP->Z2_ID,;
            "titulo": AllTrim(TMP->Z2_TITULO),;
            "status": AllTrim(TMP->Z2_STATUS);
        })
        TMP->(DbSkip())
    EndDo
    TMP->(DbCloseArea())

    // Metadados da Paginação (Muito valorizado em Frontend)
    oResponse["data"] := aTasks
    oResponse["meta"] := { "page": nP, "per_page": nLim, "count": Len(aTasks) }
    
    ::SetResponse(oResponse:ToJson())
    FreeObj(oResponse)
Return .T.

// ==========================================================================
// MÉTODO POST: Criação com Validação
// ==========================================================================
WSMETHOD POST WSREST tasks
    Local oJson := JsonObject():New()
    Local cBody := ::GetContent()
    
    ::SetContentType("application/json")

    If oJson:FromJson(cBody) != ValType("") 
        SetRestFault(400, "JSON Inválido")
        Return .F.
    EndIf

    // Validação de Campos Obrigatórios
    If ValType(oJson["titulo"]) == "U" .Or. Empty(oJson["titulo"])
        SetRestFault(400, "Campo 'titulo' é obrigatório")
        Return .F.
    EndIf

    // Gravação Segura (RecLock)
    DbSelectArea("SZ2")
    If RecLock("SZ2", .T.)
        SZ2->Z2_ID     := GetSX8Num("SZ2", "Z2_ID")
        SZ2->Z2_TITULO := Upper(SafeStr(oJson["titulo"], "")) // Sanitização
        SZ2->Z2_STATUS := "PENDENTE"
        SZ2->(MsUnlock())
        
        ::SetStatus(201) // Created
        ::SetResponse('{"id":"' + SZ2->Z2_ID + '", "message":"Criado com sucesso"}')
    Else
        SetRestFault(500, "Erro ao gravar registro")
    EndIf
    
    FreeObj(oJson)
Return .T.

// ==========================================================================
// MÉTODO PUT: Atualização (Idempotente)
// ==========================================================================
WSMETHOD PUT WSRECEIVE idTask WSREST tasks
    Local oJson := JsonObject():New()
    Local cBody := ::GetContent()

    ::SetContentType("application/json")

    If Empty(::idTask)
        SetRestFault(400, "ID não informado na URL")
        Return .F.
    EndIf

    oJson:FromJson(cBody)

    // Busca o registro para alterar
    DbSelectArea("SZ2")
    SZ2->(DbSetOrder(1)) // Índice por ID
    If !SZ2->(DbSeek(xFilial("SZ2") + ::idTask))
        SetRestFault(404, "Tarefa não encontrada")
        Return .F.
    EndIf

    If RecLock("SZ2", .F.) // .F. = Alteração
        // Só atualiza se o campo veio no JSON (Patch behavior)
        If ValType(oJson["titulo"]) != "U"
            SZ2->Z2_TITULO := Upper(oJson["titulo"])
        EndIf
        If ValType(oJson["status"]) != "U"
            SZ2->Z2_STATUS := Upper(oJson["status"])
        EndIf
        
        SZ2->(MsUnlock())
        ::SetResponse('{"message":"Atualizado com sucesso"}')
    Else
        SetRestFault(500, "Registro bloqueado por outro usuário")
    EndIf

    FreeObj(oJson)
Return .T.

// ==========================================================================
// MÉTODO DELETE: Remoção Física ou Lógica
// ==========================================================================
WSMETHOD DELETE WSRECEIVE idTask WSREST tasks
    ::SetContentType("application/json")

    If Empty(::idTask)
        SetRestFault(400, "ID obrigatório")
        Return .F.
    EndIf

    DbSelectArea("SZ2")
    SZ2->(DbSetOrder(1))
    If !SZ2->(DbSeek(xFilial("SZ2") + ::idTask))
        SetRestFault(404, "Tarefa não encontrada")
        Return .F.
    EndIf

    If RecLock("SZ2", .F.)
        SZ2->(DbDelete()) // Marca como deletado (* no banco)
        SZ2->(MsUnlock())
        ::SetStatus(204) // No Content (Sucesso sem corpo)
    Else
        SetRestFault(500, "Erro ao excluir")
    EndIf
Return .T.

// ==========================================================================
// HELPERS (Funções Auxiliares) - O Segredo do Código Limpo
// ==========================================================================

// Busca Unitária (Separada para não poluir o GET principal)
Method GetOne(cId) Class tasks
    Local oJson := JsonObject():New()
    
    DbSelectArea("SZ2")
    SZ2->(DbSetOrder(1))
    If SZ2->(DbSeek(xFilial("SZ2") + cId))
        oJson["id"]     := SZ2->Z2_ID
        oJson["titulo"] := AllTrim(SZ2->Z2_TITULO)
        oJson["status"] := AllTrim(SZ2->Z2_STATUS)
        ::SetResponse(oJson:ToJson())
    Else
        SetRestFault(404, "Tarefa não encontrada")
    EndIf
    FreeObj(oJson)
Return .T.

// Função para tratar Nulos (Null Safety)
Static Function SafeStr(uVal, cDefault)
Return If(ValType(uVal) == "C", uVal, cDefault)
