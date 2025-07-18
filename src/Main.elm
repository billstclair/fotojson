port module Main exposing (main)

{-| TODO:

Global persistence via Amazon database.

"Add link" button, pulls from clipboard and merges that address with current.

-}

import AssocSet as AS exposing (Set)
import Browser exposing (Document, UrlRequest(..))
import Browser.Dom as Dom
import Browser.Events as Events exposing (Visibility(..))
import Browser.Navigation as Navigation exposing (Key)
import Cmd.Extra exposing (addCmd, withCmd, withCmds, withNoCmd)
import Dict exposing (Dict)
import Html exposing (Attribute, Html, a, div, embed, hr, img, input, option, p, select, span, table, text, textarea, tr)
import Html.Attributes as Attributes exposing (checked, class, colspan, disabled, height, href, property, selected, src, style, target, title, type_, value, width)
import Html.Events exposing (on, onBlur, onClick, onFocus, onInput, targetValue)
import Html.Lazy as Lazy
import Http
import Json.Decode as JD exposing (Decoder)
import Json.Decode.Pipeline as DP exposing (custom, hardcoded, optional, required)
import Json.Encode as JE exposing (Value)
import List.Extra as LE
import PortFunnel.LocalStorage as LocalStorage
import PortFunnels exposing (FunnelDict, Handler(..), State)
import Process
import String.Extra as SE
import Swipe
import Task exposing (Task, succeed)
import Time exposing (Posix)
import Url exposing (Url)
import Url.Parser as Parser exposing ((<?>), Parser)
import Url.Parser.Query as Query


type alias Source =
    { src : String
    , label : Maybe String
    , url : Maybe String
    }


canonicalizeSource : Source -> Source
canonicalizeSource source =
    let
        src =
            urlDisplay source.src

        default =
            getLabelFromFileName source.src

        maybeLabel =
            case source.label of
                Nothing ->
                    Nothing

                Just label ->
                    if label == default then
                        Nothing

                    else
                        nothingIfBlank label

        maybeUrl =
            case source.url of
                Nothing ->
                    Nothing

                Just url ->
                    nothingIfBlank url
    in
    if source.src == src && source.label == maybeLabel && source.url == maybeUrl then
        source

    else
        { source
            | src = src
            , label = maybeLabel
            , url = maybeUrl
        }


sourceLabel : Source -> String
sourceLabel s =
    case s.label of
        Just label ->
            label

        Nothing ->
            getLabelFromFileName s.src


sourceUrl : Source -> String
sourceUrl s =
    case s.url of
        Just url ->
            url

        Nothing ->
            ""


type alias SourcePanel =
    { name : String
    , panels : List Source
    }


type alias Model =
    { title : String
    , url : Url
    , key : Key
    , sources : List Source
    , lastSources : List String
    , srcIdx : Int
    , sourcePanels : List SourcePanel
    , sourcePanelIdx : Int
    , switchPeriod : String
    , switchEnabled : Bool
    , showControls : Bool
    , showEditingSources : Bool
    , showHelp : Bool
    , mergeEditingSources : Bool
    , showSearch : Bool

    -- Non-persistent below here
    , settings : Maybe AppSettings
    , err : Maybe String
    , gesture : Swipe.Gesture
    , time : Int
    , lastSwapTime : Int
    , visibility : Visibility
    , reallyDeleteState : Bool
    , defaultSources : List Source -- written, but not yet read
    , editingIdx : Int
    , editingIdxStr : String
    , editingSrc : String
    , editingLabel : String
    , editingUrl : String
    , copyFrom : CopyOption
    , copyTo : CopyOption
    , undoModel : Maybe UndoModel
    , searchString : String
    , searchCnt : Int
    , searchStart : Int
    , lastKey : String
    , isFocused : Bool
    , clipboard : String
    , started : Started
    , funnelState : State
    }


type alias UndoModel =
    { sources : List Source
    , srcIdx : Int
    , sourcePanels : List SourcePanel

    -- Non-persistent below here
    , sourcePanelIdx : Int
    , editingIdx : Int
    , editingIdxStr : String
    , editingSrc : String
    , editingLabel : String
    , editingUrl : String
    }


modelToUndoModel : Model -> UndoModel
modelToUndoModel model =
    { sources = model.sources
    , srcIdx = model.srcIdx
    , sourcePanels = model.sourcePanels
    , sourcePanelIdx = model.sourcePanelIdx
    , editingIdx = model.editingIdx
    , editingIdxStr = model.editingIdxStr
    , editingSrc = model.editingSrc
    , editingLabel = model.editingLabel
    , editingUrl = model.editingUrl
    }


undoModelToModel : UndoModel -> Model -> Model
undoModelToModel undoModel model =
    { model
        | sources = undoModel.sources
        , srcIdx = undoModel.srcIdx
        , sourcePanels = undoModel.sourcePanels
        , sourcePanelIdx = undoModel.sourcePanelIdx
        , editingIdx = undoModel.editingIdx
        , editingIdxStr = undoModel.editingIdxStr
        , editingSrc = undoModel.editingSrc
        , editingLabel = undoModel.editingLabel
        , editingUrl = undoModel.editingUrl
    }


type alias SavedModel =
    { sources : List Source
    , lastSources : List String
    , srcIdx : Int
    , sourcePanels : List SourcePanel
    , sourcePanelIdx : Int
    , switchPeriod : String
    , switchEnabled : Bool
    , showControls : Bool
    , showEditingSources : Bool
    , showHelp : Bool
    , mergeEditingSources : Bool
    , showSearch : Bool
    }


saveSavedModel : LocalStorage.State -> SavedModel -> Cmd Msg
saveSavedModel state savedModel =
    put state
        pk.model
        (savedModel
            |> encodeSavedModel
            |> Just
        )


modelToSavedModel : Model -> SavedModel
modelToSavedModel model =
    { sources = model.sources
    , lastSources = model.lastSources
    , srcIdx = model.srcIdx
    , sourcePanels = model.sourcePanels
    , sourcePanelIdx = model.sourcePanelIdx
    , switchPeriod = model.switchPeriod
    , switchEnabled = model.switchEnabled
    , showControls = model.showControls
    , showEditingSources = model.showEditingSources
    , showHelp = model.showHelp
    , mergeEditingSources = model.mergeEditingSources
    , showSearch = model.showSearch
    }


savedModelToModel : SavedModel -> Model -> Model
savedModelToModel savedModel model =
    { model
        | sources = savedModel.sources
        , lastSources = savedModel.lastSources
        , srcIdx = savedModel.srcIdx
        , sourcePanels = savedModel.sourcePanels
        , sourcePanelIdx = savedModel.sourcePanelIdx
        , switchPeriod = savedModel.switchPeriod
        , switchEnabled = savedModel.switchEnabled
        , showControls = savedModel.showControls
        , showEditingSources = savedModel.showEditingSources
        , showHelp = savedModel.showHelp
        , mergeEditingSources = savedModel.mergeEditingSources
        , showSearch = savedModel.showSearch
    }


idxDecoder : Int -> Decoder Int
idxDecoder default =
    JD.oneOf
        [ JD.int
        , JD.succeed default
        ]


lastSourcesDecoder : Decoder (List String)
lastSourcesDecoder =
    JD.oneOf
        [ JD.list JD.string
        , sourcesDecoder
            -- `lastSources` used to be `List Source`.
            |> JD.andThen
                (\sources ->
                    List.map .src sources
                        |> JD.succeed
                )
        ]


savedModelDecoder : Decoder SavedModel
savedModelDecoder =
    JD.succeed SavedModel
        |> required "sources" sourcesDecoder
        |> optional "lastSources" lastSourcesDecoder []
        |> optional "srcIdx" JD.int 0
        |> optional "sourcePanels" (JD.list sourcePanelDecoder) []
        |> optional "sourcePanelIdx" JD.int 0
        |> optional "switchPeriod" JD.string "5"
        |> optional "switchEnabled" JD.bool True
        |> optional "showControls" JD.bool False
        |> optional "showEditingSources" JD.bool True
        |> optional "showHelp" JD.bool True
        |> optional "mergeEditingSources" JD.bool True
        |> optional "showSearch" JD.bool False


sourcePanelDecoder : Decoder SourcePanel
sourcePanelDecoder =
    JD.succeed SourcePanel
        |> required "name" JD.string
        |> required "panels" (JD.list sourceDecoder)


encodeSourcePanel : SourcePanel -> Value
encodeSourcePanel panel =
    JE.object
        [ ( "name", JE.string panel.name )
        , ( "panels", JE.list encodeSource panel.panels )
        ]


sourcesDecoder : Decoder (List Source)
sourcesDecoder =
    JD.list sourceDecoder


sourceDecoder : Decoder Source
sourceDecoder =
    JD.oneOf
        [ JD.string
            |> JD.andThen
                (\s -> srcSource s |> JD.succeed)
        , (JD.succeed Source
            |> required "src" JD.string
            |> optional "label" (JD.nullable JD.string) Nothing
            |> optional "url" (JD.nullable JD.string) Nothing
          )
            |> JD.andThen (\s -> canonicalizeSource s |> JD.succeed)
        ]


encodeSource : Source -> Value
encodeSource { src, label, url } =
    if (label == Nothing || label == Just "") && (url == Nothing || url == Just "") then
        JE.string src

    else
        JE.object <|
            List.concat
                [ [ ( "src", JE.string src ) ]
                , case label of
                    Nothing ->
                        []

                    Just "" ->
                        []

                    Just l ->
                        [ ( "label", JE.string l ) ]
                , case url of
                    Nothing ->
                        []

                    Just "" ->
                        []

                    Just u ->
                        [ ( "url", JE.string u ) ]
                ]


encodeSavedModel : SavedModel -> Value
encodeSavedModel savedModel =
    JE.object
        [ ( "sources", JE.list encodeSource savedModel.sources )
        , ( "lastSources", JE.list JE.string savedModel.lastSources )
        , ( "srcIdx", JE.int savedModel.srcIdx )
        , ( "sourcePanels", JE.list encodeSourcePanel savedModel.sourcePanels )
        , ( "sourcePanelIdx", JE.int savedModel.sourcePanelIdx )
        , ( "switchPeriod", JE.string savedModel.switchPeriod )
        , ( "switchEnabled", JE.bool savedModel.switchEnabled )
        , ( "showControls", JE.bool savedModel.showControls )
        , ( "showEditingSources", JE.bool savedModel.showEditingSources )
        , ( "showHelp", JE.bool savedModel.showHelp )
        , ( "mergeEditingSources", JE.bool savedModel.mergeEditingSources )
        , ( "showSearch", JE.bool savedModel.showSearch )
        ]


fotoJsonUrl : String
fotoJsonUrl =
    "fotojson.jpg"


fotoJsonSource : Source
fotoJsonSource =
    srcSource fotoJsonUrl


srcSource : String -> Source
srcSource src =
    { src = urlDisplay src, label = Nothing, url = Nothing }


init : Url -> Key -> ( Model, Cmd Msg )
init url key =
    ( { title = "Foto JSON app" --overridden by `settings`
      , url = Debug.log "init, initial url" url
      , key = key
      , sources = [ fotoJsonSource ]
      , lastSources = [ fotoJsonUrl ]
      , srcIdx = 0
      , sourcePanels = []
      , sourcePanelIdx = -1
      , switchPeriod = "5"
      , switchEnabled = True
      , showControls = False
      , showEditingSources = True
      , showHelp = True
      , mergeEditingSources = True
      , showSearch = False

      -- non-persistent below here
      , settings = Nothing
      , err = Nothing
      , gesture = Swipe.blanco
      , time = 0
      , lastSwapTime = 0
      , visibility = Visible
      , reallyDeleteState = False
      , defaultSources = [ fotoJsonSource ]
      , editingIdx = 0
      , editingIdxStr = "0"
      , editingSrc = fotoJsonUrl
      , editingLabel = getLabelFromFileName fotoJsonUrl
      , editingUrl = ""
      , copyFrom = Live
      , copyTo = Clipboard
      , undoModel = Nothing
      , searchString = ""
      , searchCnt = 10
      , searchStart = 0
      , lastKey = ""
      , isFocused = False
      , clipboard = ""
      , started = NotStarted
      , funnelState = PortFunnels.initialState localStoragePrefix
      }
    , Cmd.none
    )


computeControlsJson : List Source -> String
computeControlsJson sources =
    JE.encode 2 <| JE.list encodeSource sources



---
--- Persistence
---


put : LocalStorage.State -> String -> Maybe Value -> Cmd Msg
put state key value =
    let
        prefix =
            LocalStorage.getPrefix state
    in
    localStorageSend state
        (LocalStorage.put (Debug.log ("put " ++ prefix) key) value)


get : LocalStorage.State -> String -> Cmd Msg
get state key =
    let
        prefix =
            LocalStorage.getPrefix state
    in
    localStorageSend state
        (LocalStorage.get <| Debug.log ("get " ++ prefix) key)


clearKeys : LocalStorage.State -> String -> Cmd Msg
clearKeys state prefix =
    localStorageSend state (LocalStorage.clear prefix)


localStoragePrefix : String
localStoragePrefix =
    --overridden by settings
    "fotojson"


getLocalStoragePrefix : Maybe AppSettings -> String
getLocalStoragePrefix maybeSettings =
    case maybeSettings of
        Nothing ->
            localStoragePrefix

        Just settings ->
            settings.localStoragePrefix


localStorageSend : LocalStorage.State -> LocalStorage.Message -> Cmd Msg
localStorageSend state message =
    LocalStorage.send (getCmdPort LocalStorage.moduleName ())
        message
        state


type Msg
    = Noop
    | OnUrlChange Url
    | OnUrlRequest UrlRequest
    | Swipe Swipe.Event
    | EndSwipe Swipe.Event
    | SequenceCmds (List (Cmd Msg))
    | GotIndex String Bool (Result Http.Error (List Source))
    | SetDefaultSources (List Source)
    | FinishUrlParse Url (Maybe String) (Maybe (List Source)) Bool
    | MouseDown
    | ReceiveTime Posix
    | SetVisible Visibility
    | SetSrcIdx String
    | OnKeyPress Bool String
    | InputSwitchPeriod String
    | ToggleSwitchEnabled
    | ToggleControls
    | ToggleShowEditingSources
    | ToggleShowHelp
    | ToggleMergeEditingSources
    | ToggleShowSearch
    | DeleteAll
    | AddEditingSrc
    | ChangeEditingSrc
    | MoveEditingSrc
    | LookupEditingSrc
    | DeleteEditingSrc
    | InputEditingIdxStr String
    | InputEditingSrc String
    | InputEditingName String
    | InputEditingUrl String
    | AddSourcePanel Bool
    | SaveRestoreSourcePanel Bool
    | DeleteSourcePanel
    | MoveSourcePanelUp Bool
    | SelectSourcePanel Int
    | InputEditingPanelName String
    | Copy
    | SetCopyFrom String
    | SetCopyTo String
    | Undo
    | InputSearchString String
    | SearchMore Bool Int
    | ScrollSearch Bool Int
    | Focus Bool
    | InputClipboard String
    | ReadClipboard
    | ClipboardContents String
    | WriteClipboard
    | ReloadFromServer
    | DeleteState
    | Process Value
    | ReceiveSettings (Maybe AppSettings)


swapInterval : Model -> Int
swapInterval model =
    (case String.toFloat model.switchPeriod of
        Just f ->
            max 1 f

        Nothing ->
            5
    )
        * 1000
        |> round


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    let
        doUpdate =
            case msg of
                Noop ->
                    False

                Focus _ ->
                    False

                ReceiveTime _ ->
                    False

                DeleteState ->
                    False

                Process _ ->
                    False

                ReceiveSettings _ ->
                    False

                GotIndex _ _ _ ->
                    False

                SetDefaultSources _ ->
                    False

                SetVisible _ ->
                    False

                SequenceCmds _ ->
                    False

                _ ->
                    True

        partOfCommandZ =
            case msg of
                OnKeyPress isDown key ->
                    not isDown
                        || (keyIsCommand key
                                || (keyIsCommand model.lastKey && key == "z")
                           )

                _ ->
                    False

        notUndo =
            msg /= Undo && not partOfCommandZ

        noErrModel =
            if doUpdate then
                { model | err = Nothing }

            else
                model

        undoneModel =
            if doUpdate && notUndo then
                { noErrModel | undoModel = Nothing }

            else
                noErrModel

        ( mdl, cmd ) =
            updateInternal doUpdate
                msg
                undoneModel
    in
    if doUpdate && mdl.started == Started then
        let
            savedMdl =
                modelToSavedModel mdl

            savedModel =
                modelToSavedModel model
        in
        if savedMdl == savedModel then
            mdl |> withCmd cmd

        else
            let
                m =
                    Debug.log "update, msg" msg
            in
            mdl
                |> withCmds
                    [ cmd, saveSavedModel mdl.funnelState.storage savedMdl ]

    else
        mdl |> withCmd cmd


keyIsCommand : String -> Bool
keyIsCommand key =
    key == "Control" || key == "Meta"


{-| Handle `Swipe event` in `updateInternal` below.
-}
endSwipe : Swipe.Event -> Model -> ( Model, Cmd Msg )
endSwipe event model =
    let
        gesture =
            Swipe.record event model.gesture

        mdl =
            { model | gesture = Swipe.blanco }

        sensitivity =
            10

        ( isTap, isLeftSwipe, isRightSwipe ) =
            ( Swipe.isTap gesture
            , Swipe.isLeftSwipe sensitivity gesture
            , Swipe.isRightSwipe sensitivity gesture
            )
    in
    ( if isTap || isLeftSwipe then
        nextImage mdl

      else if isRightSwipe then
        prevImage mdl

      else
        mdl
    , Cmd.none
    )


updateInternal : Bool -> Msg -> Model -> ( Model, Cmd Msg )
updateInternal doUpdate msg modelIn =
    let
        model =
            if msg == DeleteState || not doUpdate then
                modelIn

            else
                { modelIn | reallyDeleteState = False }
    in
    case msg of
        OnUrlChange url ->
            ( model, Cmd.none )

        OnUrlRequest urlRequest ->
            ( model, Cmd.none )

        Swipe event ->
            { model | gesture = Swipe.record event model.gesture }
                |> withNoCmd

        EndSwipe event ->
            endSwipe event model

        FinishUrlParse url maybeTitle maybeSources setSourceList ->
            finishUrlParse url maybeTitle maybeSources setSourceList model

        MouseDown ->
            ( nextImage model, Cmd.none )

        ReceiveTime posix ->
            let
                millis =
                    Time.posixToMillis posix

                lastSwapTime =
                    model.lastSwapTime
            in
            let
                m =
                    { model
                        | time = millis
                        , lastSwapTime =
                            if lastSwapTime == 0 then
                                millis

                            else
                                lastSwapTime
                    }
            in
            if
                (m.visibility == Visible)
                    && m.switchEnabled
                    && (millis >= m.lastSwapTime + swapInterval m)
            then
                ( nextImage { m | lastSwapTime = millis }, Cmd.none )

            else
                ( m, Cmd.none )

        SetVisible v ->
            ( { model | visibility = Debug.log "visibility" v }, Cmd.none )

        SetSrcIdx idxStr ->
            digitKey idxStr model
                |> withNoCmd

        OnKeyPress isDown key ->
            let
                ( leftKeys, rightKeys ) =
                    if model.isFocused then
                        ( [ "ArrowLeft" ]
                        , [ "ArrowRight" ]
                        )

                    else
                        ( [ "ArrowLeft", "j", "J", "d", "D", "s", "S" ]
                        , [ "ArrowRight", "l", "L", "k", "K", "f", "F" ]
                        )

                lastKey =
                    model.lastKey

                mdl =
                    { model | lastKey = key }

                lastKeyWasCommand =
                    not model.isFocused
                        && keyIsCommand lastKey
            in
            if not isDown then
                { mdl | lastKey = "" } |> withNoCmd

            else if List.member key leftKeys then
                prevImage mdl |> withNoCmd

            else if List.member key rightKeys then
                nextImage mdl |> withNoCmd

            else if not model.isFocused && key >= "0" && key <= "9" then
                digitKey key mdl |> withNoCmd

            else if lastKeyWasCommand && (key == "z") then
                undo mdl |> withNoCmd

            else if lastKeyWasCommand && (key == "c") then
                copyItems
                    { model
                        | copyFrom = Live
                        , copyTo = Clipboard
                    }

            else if lastKeyWasCommand && (key == "v") then
                copyItems
                    { model
                        | copyFrom = Clipboard
                        , copyTo = Live
                    }

            else
                mdl |> withNoCmd

        InputSwitchPeriod string ->
            { model | switchPeriod = string }
                |> withNoCmd

        SearchMore morep matchCnt ->
            let
                searchCnt =
                    model.searchCnt

                newCnt =
                    if morep then
                        if searchCnt < 50 then
                            50

                        else if searchCnt == 50 then
                            100

                        else
                            searchCnt + 100

                    else if searchCnt > 100 then
                        searchCnt - 100

                    else if searchCnt > 50 then
                        50

                    else
                        10

                newStart =
                    if model.searchStart == 0 then
                        model.searchStart

                    else
                        max 0 <| min model.searchStart <| matchCnt - newCnt
            in
            { model
                | searchCnt = newCnt
                , searchStart = newStart
            }
                |> withNoCmd

        ScrollSearch downp matchCnt ->
            let
                mdl =
                    if downp then
                        let
                            maxStart =
                                matchCnt - model.searchCnt
                        in
                        if model.searchStart >= maxStart then
                            model

                        else
                            { model
                                | searchStart =
                                    min maxStart <| model.searchStart + model.searchCnt
                            }

                    else if model.searchStart <= 0 then
                        model

                    else
                        { model
                            | searchStart =
                                max 0 <| model.searchStart - model.searchCnt
                        }
            in
            mdl |> withNoCmd

        ToggleSwitchEnabled ->
            ( { model
                | switchEnabled = not model.switchEnabled
                , lastSwapTime = model.time
              }
            , Cmd.none
            )

        ToggleControls ->
            { model
                | showControls =
                    not model.showControls
            }
                |> withNoCmd

        ToggleShowEditingSources ->
            { model | showEditingSources = not model.showEditingSources }
                |> withNoCmd

        ToggleShowHelp ->
            { model | showHelp = not model.showHelp }
                |> withNoCmd

        ToggleMergeEditingSources ->
            { model | mergeEditingSources = not model.mergeEditingSources }
                |> withNoCmd

        ToggleShowSearch ->
            { model | showSearch = not model.showSearch }
                |> withNoCmd

        DeleteAll ->
            let
                newSources =
                    List.take 1 model.sources
            in
            { model
                | sources = newSources
                , srcIdx = 0
                , undoModel = Just <| modelToUndoModel model
            }
                |> initializeEditingFields
                |> withNoCmd

        AddEditingSrc ->
            addSource (String.toInt model.editingIdxStr)
                { src = model.editingSrc
                , label = Just model.editingLabel
                , url = Just model.editingUrl
                }
                False
                { model
                    | undoModel = Just <| modelToUndoModel model
                }
                |> withNoCmd

        ChangeEditingSrc ->
            let
                idx =
                    model.editingIdx

                sources =
                    model.sources
            in
            case LE.getAt idx sources of
                Nothing ->
                    model |> withNoCmd

                Just source ->
                    let
                        src =
                            model.editingSrc

                        newSource =
                            { source
                                | src = src
                                , label = Just model.editingLabel
                                , url = Just model.editingUrl
                            }
                                |> canonicalizeSource

                        newSources =
                            LE.setAt idx newSource sources
                    in
                    { model
                        | sources = newSources
                        , lastSources =
                            (newSource.src :: model.lastSources)
                                |> uniqueifyList
                        , srcIdx = idx
                        , undoModel = Just <| modelToUndoModel model
                        , err = Just msgs.changeSource
                    }
                        |> setEditingFields idx newSource
                        |> withNoCmd

        MoveEditingSrc ->
            case LE.getAt model.editingIdx model.sources of
                Nothing ->
                    model |> withNoCmd

                Just source ->
                    let
                        sources =
                            LE.removeAt model.editingIdx model.sources

                        idx =
                            Maybe.withDefault -1 <| String.toInt model.editingIdxStr

                        ( newIdx, newSources ) =
                            insertInList idx source sources

                        mdl =
                            { model
                                | sources = newSources
                                , srcIdx = newIdx
                                , undoModel = Just <| modelToUndoModel model
                                , err = Just msgs.moveSource
                            }
                    in
                    mdl
                        |> setEditingFields newIdx source
                        |> withNoCmd

        LookupEditingSrc ->
            let
                idx =
                    Maybe.withDefault -1 <| String.toInt model.editingIdxStr
            in
            case LE.getAt idx model.sources of
                Nothing ->
                    model |> withNoCmd

                Just source ->
                    { model
                        | undoModel = Just <| modelToUndoModel model
                        , err = Just msgs.lookupSource
                    }
                        |> setEditingFields idx source
                        |> withNoCmd

        DeleteEditingSrc ->
            if List.length model.sources <= 1 then
                model |> withNoCmd

            else
                let
                    newSources =
                        LE.removeAt model.editingIdx model.sources

                    newIdx =
                        max 0 <| model.editingIdx - 1

                    mdl =
                        { model
                            | sources = newSources
                            , srcIdx = newIdx
                            , undoModel = Just <| modelToUndoModel model
                            , err = Just msgs.deleteSource
                        }
                in
                case LE.getAt newIdx newSources of
                    Nothing ->
                        model |> withNoCmd

                    Just source ->
                        setEditingFields newIdx source mdl
                            |> withNoCmd

        InputEditingIdxStr idxstr ->
            { model | editingIdxStr = idxstr }
                |> withNoCmd

        InputEditingSrc editingSrc ->
            { model
                | editingSrc = editingSrc
                , editingLabel =
                    if model.editingLabel == "" then
                        getLabelFromFileName editingSrc

                    else if model.editingLabel == getLabelFromFileName model.editingSrc then
                        ""

                    else
                        model.editingLabel
            }
                |> withNoCmd

        InputEditingName name ->
            { model | editingLabel = name }
                |> withNoCmd

        InputEditingUrl url ->
            { model | editingUrl = url }
                |> withNoCmd

        AddSourcePanel firstp ->
            let
                name =
                    newSourcePanelName model.sourcePanels

                idx =
                    if firstp then
                        0

                    else
                        model.sourcePanelIdx + 1

                panel =
                    { name = name, panels = model.sources }

                ( newIdx, panels ) =
                    Debug.log ("insertInList " ++ String.fromInt idx) <|
                        insertInList idx panel model.sourcePanels
            in
            { model
                | sourcePanels = panels
                , sourcePanelIdx = newIdx
                , undoModel = Just <| modelToUndoModel model
                , err = Just msgs.addSourcePanel
            }
                |> withCmd (focusInput ids.sourcePanelName)

        SaveRestoreSourcePanel savep ->
            case LE.getAt model.sourcePanelIdx model.sourcePanels of
                Nothing ->
                    model |> withNoCmd

                Just panel ->
                    if savep then
                        { model
                            | sources = panel.panels
                            , srcIdx = 0
                            , undoModel = Just <| modelToUndoModel model
                            , err = Just msgs.saveSourcePanel
                        }
                            |> initializeEditingFields
                            |> withNoCmd

                    else
                        { model
                            | sourcePanels =
                                LE.setAt model.sourcePanelIdx
                                    { panel | panels = model.sources }
                                    model.sourcePanels
                            , undoModel = Just <| modelToUndoModel model
                            , err = Just msgs.restoreSourcePanel
                        }
                            |> withNoCmd

        DeleteSourcePanel ->
            { model
                | sourcePanels =
                    LE.removeAt model.sourcePanelIdx model.sourcePanels
                , sourcePanelIdx = -1
                , undoModel = Just <| modelToUndoModel model
                , err = Just msgs.deleteSourcePanel
            }
                |> withNoCmd

        MoveSourcePanelUp moveUp ->
            if model.sourcePanelIdx < 0 then
                model |> withNoCmd

            else
                let
                    idx =
                        model.sourcePanelIdx
                            + (if moveUp then
                                -1

                               else
                                1
                              )
                in
                if idx < 0 || idx >= List.length model.sourcePanels then
                    model |> withNoCmd

                else
                    let
                        sourcePanelIdx =
                            model.sourcePanelIdx

                        sourcePanels =
                            model.sourcePanels
                    in
                    case LE.getAt sourcePanelIdx sourcePanels of
                        Nothing ->
                            model |> withNoCmd

                        Just panel ->
                            let
                                panels =
                                    LE.removeAt sourcePanelIdx sourcePanels

                                ( newIdx, newSourcePanels ) =
                                    insertInList idx panel panels
                            in
                            { model
                                | sourcePanels = newSourcePanels
                                , sourcePanelIdx = newIdx
                                , undoModel = Just <| modelToUndoModel model
                                , err = Just msgs.moveSourcePanel
                            }
                                |> withNoCmd

        SelectSourcePanel idx ->
            selectSourcePanel idx model

        InputEditingPanelName name ->
            case LE.getAt model.sourcePanelIdx model.sourcePanels of
                Nothing ->
                    model |> withNoCmd

                Just panel ->
                    { model
                        | sourcePanels =
                            LE.setAt model.sourcePanelIdx
                                { panel | name = name }
                                model.sourcePanels
                    }
                        |> withNoCmd

        Copy ->
            copyItems model

        SetCopyFrom option ->
            { model | copyFrom = labelCopyOption option }
                |> fixCopyFromEqualsTo False
                |> withNoCmd

        SetCopyTo option ->
            { model | copyTo = labelCopyOption option }
                |> fixCopyFromEqualsTo True
                |> withNoCmd

        Undo ->
            undo model |> withNoCmd

        InputSearchString s ->
            { model
                | searchString = s
                , searchStart = 0
            }
                |> withNoCmd

        Focus isFocused ->
            { model | isFocused = isFocused }
                |> withNoCmd

        InputClipboard s ->
            { model | clipboard = s }
                |> withNoCmd

        ReadClipboard ->
            { model | clipboard = "" }
                |> withCmd (clipboardRead "")

        ClipboardContents s ->
            { model | clipboard = s }
                |> finishCopyFromClipboard s

        WriteClipboard ->
            { model | clipboard = "" }
                |> withCmd (clipboardWrite model.clipboard)

        ReloadFromServer ->
            model
                |> withCmd Navigation.reloadAndSkipCache

        DeleteState ->
            if model.reallyDeleteState then
                let
                    ( mdl, cmd ) =
                        init model.url model.key
                in
                { mdl
                    | reallyDeleteState = False
                    , started = Started
                }
                    |> withCmds
                        [ cmd
                        , clearKeys mdl.funnelState.storage ""
                        , getIndexJson model.url True
                        ]

            else
                { model | reallyDeleteState = True }
                    |> withNoCmd

        Noop ->
            model |> withNoCmd

        SequenceCmds commands ->
            case commands of
                [] ->
                    model |> withNoCmd

                first :: rest ->
                    model
                        |> withCmds
                            [ first
                            , delay 1 <| SequenceCmds rest
                            ]

        GotIndex filename setSourcesList result ->
            case result of
                Err e ->
                    if filename == indexJson then
                        let
                            url =
                                indexSampleJson
                        in
                        model
                            |> withCmd
                                (httpGetJsonFile url <|
                                    GotIndex url setSourcesList
                                )

                    else
                        { model | err = Just <| Debug.toString e }
                            |> withNoCmd

                Ok sources ->
                    let
                        indexSources =
                            sources

                        mdl =
                            initializeEditingFields <|
                                if setSourcesList then
                                    { model | sources = indexSources }

                                else
                                    model
                                        |> maybeAddNewSources indexSources
                    in
                    { mdl
                        | defaultSources = indexSources
                        , lastSources =
                            List.map .src mdl.sources
                                |> uniqueifyList
                    }
                        |> withCmd (SetDefaultSources indexSources |> msgCmd)

        SetDefaultSources sources ->
            { model
                | sourcePanels =
                    setSourcePanelNamed "default"
                        (Debug.log "SetDefaultSources" sources)
                        model.sourcePanels
            }
                |> withNoCmd

        Process value ->
            case
                PortFunnels.processValue funnelDict
                    value
                    model.funnelState
                    model
            of
                Err error ->
                    { model | err = Just <| Debug.toString error }
                        |> withNoCmd

                Ok res ->
                    res

        ReceiveSettings settings ->
            { model
                | settings =
                    Debug.log "settings" settings
                , funnelState =
                    PortFunnels.initialState <| getLocalStoragePrefix settings
            }
                |> withNoCmd


setSourcePanelNamed : String -> List Source -> List SourcePanel -> List SourcePanel
setSourcePanelNamed name sources sourcePanels =
    case LE.find (\sp -> sp.name == name) sourcePanels of
        Nothing ->
            { name = name
            , panels = sources
            }
                :: sourcePanels

        Just panel ->
            if panel.panels == sources then
                sourcePanels

            else
                case LE.elemIndex panel sourcePanels of
                    Nothing ->
                        -- Can't happen
                        sourcePanels

                    Just idx ->
                        LE.setAt idx { panel | panels = sources } sourcePanels


undo : Model -> Model
undo model =
    case model.undoModel of
        Nothing ->
            model

        Just undoModel ->
            let
                mdl =
                    undoModelToModel undoModel model
            in
            { mdl | undoModel = Nothing }
                -- It could be argued that the editing fields
                -- should return to what they were before the
                -- undone command. I found this confusing
                |> initializeEditingFields


selectSourcePanel : Int -> Model -> ( Model, Cmd Msg )
selectSourcePanel idx model =
    if idx > List.length model.sourcePanels then
        model |> withNoCmd

    else
        let
            ( i, cmd ) =
                if idx == model.sourcePanelIdx then
                    ( -1, Cmd.none )

                else
                    ( idx
                    , focusInput ids.sourcePanelName
                    )
        in
        { model | sourcePanelIdx = i }
            |> withCmd cmd


ids =
    { sourcePanelName = "sourcePanelName"
    }


focusInput : String -> Cmd Msg
focusInput id =
    Task.perform SequenceCmds <|
        Task.succeed
            [ Dom.focus id
                |> Task.attempt (\_ -> Noop)
            , selectElement id
            ]


fixCopyFromEqualsTo : Bool -> Model -> Model
fixCopyFromEqualsTo setCopyFrom model =
    if model.copyFrom /= model.copyTo then
        model

    else
        let
            newOption =
                if model.copyFrom /= Live then
                    Live

                else
                    Clipboard
        in
        if setCopyFrom then
            { model | copyFrom = newOption }

        else
            { model | copyTo = newOption }


finishCopyFromClipboard : String -> Model -> ( Model, Cmd Msg )
finishCopyFromClipboard s model =
    case JD.decodeString (JD.list sourceDecoder) s of
        Err _ ->
            case model.copyTo of
                Live ->
                    addSource (Just <| model.srcIdx + 1) (srcSource s) True model
                        |> withNoCmd

                Panel ->
                    case model.copyFrom of
                        Live ->
                            copyUrlToPanel s model

                        _ ->
                            model |> withNoCmd

                _ ->
                    model |> withNoCmd

        Ok sources ->
            case model.copyTo of
                Clipboard ->
                    model |> withNoCmd

                Live ->
                    { model
                        | sources = sources
                        , srcIdx = 0
                        , undoModel = Just <| modelToUndoModel model
                        , err = Just msgs.copyClipboardToLive
                    }
                        |> (if isEditingCurrent model then
                                initializeEditingFields

                            else
                                identity
                           )
                        |> withNoCmd

                Displayed ->
                    model |> withNoCmd

                Panel ->
                    copyToPanel (copyOptionLabel Live) sources model


copyUrlToPanel : String -> Model -> ( Model, Cmd Msg )
copyUrlToPanel s model =
    let
        source =
            srcSource s
    in
    case LE.getAt model.sourcePanelIdx model.sourcePanels of
        Nothing ->
            model |> withNoCmd

        Just panel ->
            let
                panelCnt =
                    List.length panel.panels
            in
            { model
                | sourcePanels =
                    LE.setAt model.sourcePanelIdx
                        { panel | panels = LE.setAt panelCnt source panel.panels }
                        model.sourcePanels
            }
                |> withNoCmd


copyToPanel : String -> List Source -> Model -> ( Model, Cmd Msg )
copyToPanel fromName sources model =
    let
        idx =
            model.sourcePanelIdx

        panels =
            model.sourcePanels
    in
    case LE.getAt idx panels of
        Nothing ->
            let
                name =
                    newSourcePanelName panels
            in
            { model
                | sourcePanels =
                    { name = name
                    , panels = model.sources
                    }
                        :: panels
                , sourcePanelIdx = 0
                , undoModel = Just <| modelToUndoModel model
                , err = Just <| msgs.addSourcePanel ++ " from " ++ fromName
            }
                |> withCmd (focusInput ids.sourcePanelName)

        Just panel ->
            let
                newPanel =
                    { name = panel.name
                    , panels = model.sources
                    }
            in
            { model
                | sourcePanels =
                    LE.setAt idx newPanel panels
                , undoModel = Just <| modelToUndoModel model
                , err = Just <| msgs.overwriteSourcePanel ++ " from " ++ fromName
            }
                |> withCmd (focusInput ids.sourcePanelName)


copyItems : Model -> ( Model, Cmd Msg )
copyItems model =
    if model.copyFrom == model.copyTo then
        model |> withNoCmd

    else
        case model.copyFrom of
            Clipboard ->
                { model | clipboard = "" }
                    |> withCmd (clipboardRead "")

            Panel ->
                let
                    undoModel =
                        Just <| modelToUndoModel model
                in
                case LE.getAt model.sourcePanelIdx model.sourcePanels of
                    Nothing ->
                        model |> withNoCmd

                    Just panel ->
                        case model.copyTo of
                            Panel ->
                                model |> withNoCmd

                            Live ->
                                { model
                                    | sources = panel.panels
                                    , srcIdx = 0
                                    , undoModel = undoModel
                                    , err =
                                        Just <|
                                            msgs.copyPanel
                                                ++ " to "
                                                ++ copyOptionLabel Live
                                }
                                    |> initializeEditingFields
                                    |> withNoCmd

                            Displayed ->
                                -- TODO
                                model |> withNoCmd

                            Clipboard ->
                                let
                                    json =
                                        JE.list encodeSource panel.panels
                                in
                                { model
                                    | err =
                                        Just <|
                                            msgs.copyPanel
                                                ++ " to "
                                                ++ copyOptionLabel Clipboard
                                }
                                    |> withCmd (clipboardWrite <| JE.encode 0 json)

            Displayed ->
                case LE.getAt model.sourcePanelIdx model.sourcePanels of
                    Nothing ->
                        model |> withNoCmd

                    Just panel ->
                        case LE.getAt model.srcIdx model.sources of
                            Nothing ->
                                model |> withNoCmd

                            Just source ->
                                { model
                                    | sourcePanels =
                                        LE.setAt model.sourcePanelIdx
                                            { panel
                                                | panels =
                                                    panel.panels ++ [ source ]
                                            }
                                            model.sourcePanels
                                    , sources = LE.remove source model.sources
                                }
                                    |> withNoCmd

            Live ->
                case model.copyTo of
                    Live ->
                        model |> withNoCmd

                    Displayed ->
                        -- TODO
                        model |> withNoCmd

                    Clipboard ->
                        let
                            json =
                                JE.list encodeSource model.sources
                        in
                        { model
                            | err =
                                Just <|
                                    msgs.copyLive
                                        ++ " to "
                                        ++ copyOptionLabel Clipboard
                        }
                            |> withCmd (clipboardWrite <| JE.encode 0 json)

                    Panel ->
                        copyToPanel (copyOptionLabel Live) model.sources model


uniqueifyList : List a -> List a
uniqueifyList list =
    AS.fromList list |> AS.toList


initializeEditingFields : Model -> Model
initializeEditingFields model =
    case LE.getAt model.srcIdx model.sources of
        Just source ->
            setEditingFields model.srcIdx source model

        Nothing ->
            if model.srcIdx == 0 then
                model

            else
                initializeEditingFields { model | srcIdx = 0 }


setEditingFields : Int -> Source -> Model -> Model
setEditingFields idx source model =
    let
        label =
            case source.label of
                Nothing ->
                    getLabelFromFileName source.src

                Just l ->
                    l
    in
    { model
        | editingIdx = idx
        , editingIdxStr = String.fromInt idx
        , editingSrc = urlDisplay source.src
        , editingLabel = label
        , editingUrl = Maybe.withDefault "" source.url
    }


addSource : Maybe Int -> Source -> Bool -> Model -> Model
addSource maybeIdx source updateEditor model =
    let
        canonicalSource =
            canonicalizeSource source

        sources =
            model.sources

        idx =
            Maybe.withDefault -2 maybeIdx
                + 1

        ( srcIdx, newSources ) =
            insertInList idx canonicalSource sources

        editorChanged =
            updateEditor && isEditingCurrent model
    in
    { model
        | sources = newSources
        , lastSources =
            (canonicalSource.src :: model.lastSources)
                |> uniqueifyList
        , srcIdx = srcIdx
        , editingIdxStr = String.fromInt srcIdx
        , undoModel = Just <| modelToUndoModel model
        , err = Just msgs.addSource
    }
        |> (if editorChanged then
                initializeEditingFields

            else
                identity
           )


insertInList : Int -> a -> List a -> ( Int, List a )
insertInList insertIdx item items =
    let
        len =
            List.length items

        idx =
            if insertIdx < 0 || insertIdx > len then
                len

            else
                insertIdx

        ( head, tail ) =
            LE.splitAt idx items
    in
    ( idx, head ++ (item :: tail) )


getSourcePanel : Int -> List SourcePanel -> Maybe (List Source)
getSourcePanel idx panels =
    case LE.getAt idx panels of
        Nothing ->
            Nothing

        Just panel ->
            Just panel.panels


newSourcePanelName : List SourcePanel -> String
newSourcePanelName panels =
    let
        loop : Int -> String -> String
        loop index name =
            case LE.find (\p -> p.name == name) panels of
                Just _ ->
                    loop (index + 1) ("new" ++ String.fromInt (index + 1))

                Nothing ->
                    name
    in
    loop 1 "new"


maybeAddNewSources : List Source -> Model -> Model
maybeAddNewSources indexSources model =
    if not model.mergeEditingSources then
        model

    else
        let
            indexStringsSet =
                AS.fromList <| List.map urlDisplay <| List.map .src indexSources

            lastSources =
                List.map urlDisplay model.lastSources

            lastSourcesSet =
                AS.fromList lastSources

            newSourcesSet =
                AS.diff indexStringsSet lastSourcesSet

            newSources =
                Debug.log "maybeAddNewSource, newsources" <|
                    AS.toList newSourcesSet

            err =
                if newSources == [] then
                    Nothing

                else
                    Just <|
                        msgs.addNewSources
                            ++ ": "
                            ++ String.fromInt (List.length newSources)
        in
        { model
            | sources = model.sources ++ List.map srcSource newSources
            , lastSources = lastSources
            , err = err
        }


delay : Int -> msg -> Cmd msg
delay millis msg =
    Process.sleep (millis |> toFloat)
        |> Task.perform (\_ -> msg)


cdr : List a -> List a
cdr list =
    case List.tail list of
        Just tail ->
            tail

        Nothing ->
            []


dropN : Int -> List a -> List a
dropN n list =
    if n <= 0 then
        list

    else
        dropN (n - 1) <| cdr list


headTail : Int -> List Source -> ( List Source, List Source )
headTail idx editingSources =
    let
        i =
            idx + 1
    in
    ( List.take i editingSources, List.drop i editingSources )


{-| The `model` parameter is necessary here for `PortFunnels.makeFunnelDict`.
-}
getCmdPort : String -> model -> (Value -> Cmd Msg)
getCmdPort moduleName _ =
    PortFunnels.getCmdPort Process moduleName False


funnelDict : FunnelDict Model Msg
funnelDict =
    PortFunnels.makeFunnelDict
        [ LocalStorageHandler storageHandler
        ]
        getCmdPort


{-| Persistent storage keys
-}
pk =
    { model = "model"
    }


type Started
    = NotStarted
    | StartedReadingModel
    | Started


storageHandler : LocalStorage.Response -> PortFunnels.State -> Model -> ( Model, Cmd Msg )
storageHandler response state model =
    let
        mdl =
            { model
                | started =
                    if
                        LocalStorage.isLoaded state.storage
                            && (model.started == NotStarted)
                    then
                        StartedReadingModel

                    else
                        model.started
            }

        cmd =
            if
                (mdl.started == StartedReadingModel)
                    && (model.started == NotStarted)
            then
                get mdl.funnelState.storage pk.model

            else
                Cmd.none
    in
    case response of
        LocalStorage.GetResponse { label, key, value } ->
            handleGetResponse label key value mdl

        _ ->
            mdl |> withCmd cmd


handleGetResponse : Maybe String -> String -> Maybe Value -> Model -> ( Model, Cmd Msg )
handleGetResponse maybeLabel key maybeValue model =
    case maybeLabel of
        Nothing ->
            if Debug.log "handleGetResponse, key" key == pk.model then
                handleGetModel maybeValue model

            else
                model |> withNoCmd

        Just label ->
            -- This doesn't happen in this app
            case maybeValue of
                Nothing ->
                    model |> withNoCmd

                Just value ->
                    model |> withNoCmd


type alias GetArgsJson msg =
    { url : String, expect : Http.Expect msg, headers : List Http.Header }


httpGet : GetArgsJson msg -> Cmd msg
httpGet args =
    Http.request
        { method = "GET"
        , headers = args.headers
        , url = args.url
        , body = Http.emptyBody
        , expect = args.expect
        , timeout = Nothing
        , tracker = Nothing
        }


httpGetJsonFile : String -> (Result Http.Error (List Source) -> Msg) -> Cmd Msg
httpGetJsonFile url receiver =
    httpGet
        { url = url
        , expect =
            Http.expectJson receiver sourcesDecoder
        , headers =
            [ Http.header "Cache-control" "no-cache, no-store" ]
        }


indexJson : String
indexJson =
    "images/index.json"


indexSampleJson : String
indexSampleJson =
    "images/index-sample.json"


maybeParseSourcesList : List String -> Maybe (List Source)
maybeParseSourcesList strings =
    let
        folder : String -> Maybe (List Source) -> Maybe (List Source)
        folder s maybeSources =
            case maybeSources of
                Nothing ->
                    Nothing

                Just sources ->
                    case JD.decodeString sourcesDecoder s of
                        Err _ ->
                            Nothing

                        Ok newSources ->
                            sources ++ newSources |> Just
    in
    List.foldl folder (Just []) strings


maybeParseSources : String -> Maybe (List Source)
maybeParseSources string =
    case JD.decodeString sourcesDecoder string of
        Ok sources ->
            Just sources

        Err _ ->
            Nothing


msgCmd : Msg -> Cmd Msg
msgCmd msg =
    Task.perform identity (Task.succeed msg)


getIndexJson : Url -> Bool -> Cmd Msg
getIndexJson url setSourceList =
    let
        titleParser : Query.Parser (Maybe String)
        titleParser =
            Query.string "title"

        filmParser : Query.Parser (Maybe (List Source))
        filmParser =
            Query.custom "film" maybeParseSourcesList

        emptyUrl =
            Debug.log "getIndexJson, emptyUrl" <|
                { url | path = "/" }

        ( titleParse, filmParse ) =
            Debug.log "  (titleParse, filmParse)" <|
                case emptyUrl.query of
                    Nothing ->
                        ( Nothing, Nothing )

                    Just query ->
                        ( Parser.parse (Parser.top <?> titleParser) emptyUrl
                            |> Maybe.withDefault Nothing
                        , Parser.parse (Parser.top <?> filmParser) emptyUrl
                            |> Maybe.withDefault Nothing
                            |> (\f ->
                                    case f of
                                        Just [] ->
                                            Nothing

                                        _ ->
                                            f
                               )
                        )
    in
    FinishUrlParse url titleParse filmParse setSourceList |> msgCmd


finishUrlParse : Url -> Maybe String -> Maybe (List Source) -> Bool -> Model -> ( Model, Cmd Msg )
finishUrlParse url maybeTitle maybeSources setSourceList model =
    let
        mdl =
            case maybeTitle of
                Nothing ->
                    model

                Just title ->
                    { model | title = title }
    in
    case maybeSources of
        Just sources ->
            ( mdl
            , GotIndex (Url.toString url) setSourceList (Ok sources)
                |> msgCmd
            )

        Nothing ->
            let
                s =
                    Debug.log "getIndexJson" setSourceList

                indexUrl =
                    indexJson
            in
            ( mdl, httpGetJsonFile indexUrl (GotIndex indexUrl setSourceList) )


handleGetModel : Maybe Value -> Model -> ( Model, Cmd Msg )
handleGetModel maybeValue model =
    let
        model2 =
            { model
                | started = Started
                , err = Nothing
            }
    in
    case maybeValue of
        Nothing ->
            let
                s =
                    Debug.log "null model value, getIndexJson" True
            in
            model2 |> withCmd (getIndexJson model2.url True)

        Just value ->
            case JD.decodeValue savedModelDecoder value of
                Err err ->
                    { model2
                        | err =
                            Just <|
                                Debug.log "Error decoding SavedModel"
                                    (JD.errorToString err)
                    }
                        |> withCmd (getIndexJson model2.url True)

                Ok savedModel ->
                    savedModelToModel savedModel model2
                        |> withCmd (getIndexJson model2.url False)


centerFit : List (Attribute msg)
centerFit =
    [ style "max-width" "100%"
    , style "max-height" "100vh"

    --, style "margin" "auto"
    ]


digitKey : String -> Model -> Model
digitKey digit model =
    let
        idx =
            case String.toInt digit of
                Just i ->
                    i

                Nothing ->
                    0
    in
    viewImage idx model


nextImage : Model -> Model
nextImage model =
    viewImage (model.srcIdx + 1) model


prevImage : Model -> Model
prevImage model =
    viewImage (model.srcIdx - 1) model


isEditingCurrent : Model -> Bool
isEditingCurrent model =
    case String.toInt model.editingIdxStr of
        Nothing ->
            False

        Just editingIdx ->
            if editingIdx /= model.editingIdx then
                False

            else
                case LE.getAt model.editingIdx model.sources of
                    Nothing ->
                        False

                    Just source ->
                        canonicalizeSource source
                            == canonicalizeSource
                                { src = model.editingSrc
                                , label = Just model.editingLabel
                                , url = Just model.editingUrl
                                }


viewImage : Int -> Model -> Model
viewImage index model =
    let
        sources =
            model.sources

        size =
            List.length sources

        idx =
            if index < 0 then
                size - 1

            else if index >= size then
                0

            else
                index

        mdl =
            maybeSwitchEditor idx model
    in
    { mdl
        | srcIdx = idx
        , lastSwapTime = model.time
    }


maybeSwitchEditor : Int -> Model -> Model
maybeSwitchEditor idx model =
    if not <| isEditingCurrent model then
        model

    else
        case LE.getAt idx model.sources of
            Nothing ->
                model

            Just source ->
                { model
                    | editingIdx = idx
                    , editingIdxStr = String.fromInt idx
                    , editingSrc = urlDisplay source.src
                    , editingLabel =
                        case source.label of
                            Just label ->
                                label

                            Nothing ->
                                getLabelFromFileName source.src
                    , editingUrl =
                        Maybe.withDefault "" source.url
                }


getLabelFromFileName : String -> String
getLabelFromFileName filename =
    let
        noType =
            SE.leftOfBack "." filename

        name =
            SE.rightOfBack "/" noType
    in
    (if name == "" then
        noType

     else
        name
    )
        |> String.replace "-" " "
        |> String.replace "_" " "
        |> SE.toTitleCase


center : List (Attribute msg) -> List (Html msg) -> Html msg
center =
    Html.node "center"


view : Model -> Document Msg
view model =
    { title = model.title
    , body =
        [ if model.started /= Started then
            text ""

          else
            viewInternal model
        ]
    }


modelLabel : Model -> String
modelLabel model =
    case LE.getAt model.srcIdx model.sources of
        Just s ->
            case s.label of
                Just l ->
                    l

                _ ->
                    getLabelFromFileName s.src

        Nothing ->
            ""


urlType : String -> String
urlType url =
    String.split "." url
        |> List.reverse
        |> (\l ->
                case List.head l of
                    Nothing ->
                        ""

                    Just res ->
                        res
           )


imagePrefix : String
imagePrefix =
    "images/"


peoplePrefix : String
peoplePrefix =
    "people/"


nonPeopleFiles : List String
nonPeopleFiles =
    []


imgTypes : List String
imgTypes =
    String.split "," "jpg,jpeg,gif,png,svg,webp"


focusTrackingInput : List (Attribute Msg) -> List (Html Msg) -> Html Msg
focusTrackingInput attributes elements =
    input
        (List.concat
            [ attributes
            , [ onFocus <| Focus True
              , onBlur <| Focus False
              ]
            ]
        )
        elements


noPointerEvents : Attribute msg
noPointerEvents =
    style "pointer-events" "none"


embedDiv : List (Attribute Msg) -> List (Html Msg) -> Html Msg
embedDiv attributes elements =
    div [ onClick MouseDown ]
        [ embed (noPointerEvents :: attributes) elements ]


{-| These are values for `Model.err`
-}
msgs =
    { addSource = "Added new image"
    , changeSource = "Changed image"
    , moveSource = "Moved image"
    , lookupSource = "Updated editor from Live"
    , deleteSource = "Deleted image"
    , addSourcePanel = "Added Film Roll"
    , saveSourcePanel = "Film Roll made live"
    , restoreSourcePanel = "Overwrote Film Roll"
    , deleteSourcePanel = "Deleted Film Roll"
    , moveSourcePanel = "Moved Film Roll"
    , copyClipboardToLive = "Copied Clipboard to Live"
    , overwriteSourcePanel = "Overwrote Film Roll"
    , copyPanel = "Copied Film Roll"
    , copyLive = "Copied Live"
    , addNewSources = "Added new sources"
    }


isImageUrl : String -> Bool
isImageUrl url =
    let
        fileUrlType =
            urlType url
    in
    List.member fileUrlType imgTypes


viewSrc : Bool -> String -> String -> String -> Html Msg
viewSrc forTable url maxHeight maxWidth =
    let
        isImage =
            isImageUrl url
    in
    (if isImage then
        img

     else
        embedDiv
    )
        (List.concat
            [ [ src url
              , style "text-align" "center"
              , onClick MouseDown
              , if not isImage && not forTable then
                    style "height" "max-content"

                else
                    style "" ""
              , style "max-height" <|
                    if forTable then
                        maxHeight

                    else
                        "500px"
              ]
            , if forTable then
                [ style "max-width" maxWidth ]

              else if isImage && not forTable then
                centerFit

              else
                []
            , [ Swipe.onStart Swipe
              , Swipe.onMove Swipe
              , Swipe.onEnd EndSwipe
              ]
            ]
        )
        []


urlDisplay : String -> String
urlDisplay url =
    if String.startsWith "http" url then
        let
            cnt =
                if String.startsWith "https://" url then
                    8

                else
                    0
        in
        String.dropLeft cnt url

    else if String.startsWith peoplePrefix url then
        String.dropLeft (String.length peoplePrefix) url

    else
        url


computeImgSrc : Maybe Source -> Int -> ( String, String )
computeImgSrc maybeSource idx =
    case maybeSource of
        Nothing ->
            ( String.fromInt idx, "" )

        Just source ->
            let
                src =
                    if String.startsWith "http" source.src then
                        source.src

                    else
                        let
                            prefix =
                                if List.member source.src nonPeopleFiles then
                                    imagePrefix

                                else if
                                    String.startsWith peoplePrefix
                                        source.src
                                then
                                    imagePrefix

                                else if String.contains "/" source.src then
                                    "https://"

                                else if isImageUrl source.src then
                                    imagePrefix ++ peoplePrefix

                                else
                                    "https://"
                        in
                        prefix ++ source.src

                url =
                    case source.url of
                        Nothing ->
                            src

                        Just u ->
                            if u == "" then
                                src

                            else
                                u
            in
            ( src, url )


viewInternal : Model -> Html Msg
viewInternal model =
    let
        name =
            modelLabel model

        index =
            model.srcIdx

        maybeSource =
            LE.getAt index model.sources

        ( modelSrc, url ) =
            computeImgSrc maybeSource model.srcIdx
    in
    div
        [ style "text-align" "center"
        , style "margin" "auto"
        , style "max-height" "60em"
        , style "overflow" "auto"
        ]
        [ -- h2 model.title
          viewSrc False modelSrc "" ""
        , br
        , text (String.fromInt index)
        , text ": "
        , a
            [ href url
            , target "_blank"
            ]
            [ text <| name ++ " (" ++ urlType url ++ ")" ]
        , Lazy.lazy2 viewSourceLinks index model.sources
        , p
            []
            [ case model.err of
                Nothing ->
                    text ""

                Just err ->
                    span [ style "color" "red" ]
                        [ text err
                        , br
                        ]
            , let
                keys =
                    if model.isFocused then
                        "arrows"

                    else
                        "s/f, j/l, arrows,"
              in
              text <| "Click on the image to change. Or press " ++ keys ++ " or digit links above."
            , br
            , checkBox ToggleSwitchEnabled
                model.switchEnabled
                "Auto-switch images"
            , b ", period: "
            , focusTrackingInput
                [ onInput InputSwitchPeriod
                , value model.switchPeriod
                , width 2
                , style "min-height" "1em"
                , style "width" "2em"
                ]
                [ text model.switchPeriod ]
            , br
            , a
                [ href "https://github.com/billstclair/fotojson"
                , target "_blank"
                ]
                [ text "GitHub" ]
            , text " "
            , p []
                [ text "Copyright "
                , text special.copyright
                , text "2024-2025, "
                , a
                    [ href "https://billstclair.com/"
                    , target "_blank"
                    ]
                    [ text "Bill St. Clair" ]
                ]
            , p []
                [ button ReloadFromServer "Reload code from server" ]
            , p []
                [ showControlsButton model ]
            , if model.showControls then
                p []
                    [ hr [] []
                    , viewControls model
                    ]

              else
                text ""
            ]
        ]


viewClipboardTest : Model -> Html Msg
viewClipboardTest model =
    text ""


viewClipboardTestNoMore : Model -> Html Msg
viewClipboardTestNoMore model =
    p []
        [ h3 "ClipboardTest"
        , focusTrackingInput
            [ onInput InputClipboard
            , value model.clipboard
            ]
            [ text model.clipboard ]
        , text " "
        , button WriteClipboard "Write"
        , text " "
        , button ReadClipboard "Read"
        ]


viewSourceLinks : Int -> List Source -> Html Msg
viewSourceLinks index sources =
    p []
        (List.indexedMap
            (\idx s ->
                let
                    idxstr =
                        String.fromInt idx

                    idxElements =
                        [ text special.nbsp
                        , text idxstr
                        , text special.nbsp
                        ]

                    label =
                        sourceLabel s
                in
                if idx == index then
                    span [ title label ] <|
                        (idxElements ++ [ text " " ])

                else
                    span []
                        [ a
                            [ href "#"
                            , onClick <| SetSrcIdx idxstr
                            , style "text-decoration" "none"
                            , title label
                            ]
                            [ span [ style "text-decoration" "underline" ]
                                idxElements
                            ]
                        , text " "
                        ]
            )
            sources
        )


showControlsButton : Model -> Html Msg
showControlsButton model =
    button ToggleControls <|
        if model.showControls then
            "Hide Controls"

        else
            "Show Controls"


showHelpButton : Model -> Html Msg
showHelpButton model =
    button ToggleShowHelp <|
        if model.showHelp then
            "Hide help"

        else
            "Show help"


h1 : String -> Html Msg
h1 title =
    Html.h1 [] [ text title ]


h2 : String -> Html Msg
h2 title =
    Html.h2 [] [ text title ]


h3 : String -> Html Msg
h3 title =
    Html.h3 [] [ text title ]


viewControls : Model -> Html Msg
viewControls model =
    center []
        [ div []
            [ h2 "Controls"
            , p []
                [ checkBox ToggleMergeEditingSources
                    model.mergeEditingSources
                    "Merge new app images with your list."
                ]
            , viewCopyButtons model
            , viewEditingSources model
            , p []
                [ button ToggleShowSearch <|
                    if model.showSearch then
                        "Show Film Rolls"

                    else
                        "Show Search"
                ]
            , if model.showSearch then
                Lazy.lazy4 viewSearch
                    model.searchStart
                    model.searchCnt
                    model.searchString
                    model.sources

              else
                viewSourcePanels model
            , viewClipboardTest model
            , p []
                [ if model.reallyDeleteState then
                    button DeleteState "Really Delete State"

                  else
                    button DeleteState "Delete State (after confirmation)"
                ]
            , p []
                [ showControlsButton model ]
            ]
        ]


viewSaveDeleteButtons : Model -> Html Msg
viewSaveDeleteButtons model =
    p []
        [ button DeleteAll
            "Delete all"
        , text " "
        , enabledButton (model.undoModel /= Nothing) Undo "Undo"
        ]



-- encoders may depend on the strings in `copyOptions`,
-- but I'd rather they not.
-- I haven't yet written one, so it is not yet an issue.
-- Ideally, no code will depend on the strings here, so you
-- may change them at will and not break anything, though if you
-- name them all "Bite me!", you may confuse the users.


type CopyOption
    = Clipboard
    | Live
    | Displayed
    | Panel


copyOptionLabel : CopyOption -> String
copyOptionLabel copyOption =
    case copyOption of
        Clipboard ->
            "Clipboard"

        Live ->
            "Live"

        Displayed ->
            "Displayed"

        Panel ->
            "Selected Roll"


labelCopyOption : String -> CopyOption
labelCopyOption string =
    case string of
        "Clipboard" ->
            Clipboard

        "Live" ->
            Live

        "Displayed" ->
            Displayed

        "Selected Roll" ->
            Panel

        _ ->
            Live


copyPlaces : List CopyOption
copyPlaces =
    [ Live, Displayed, Clipboard, Panel ]


viewCopyButtons : Model -> Html Msg
viewCopyButtons model =
    p []
        [ button Copy "Copy"
        , b " from: "
        , select
            [ onInput SetCopyFrom ]
            (List.map
                (\option ->
                    viewOption isFromSelected
                        isFromSelectable
                        option
                        model
                )
                copyPlaces
            )
        , text " "
        , b "to: "
        , select [ onInput SetCopyTo ]
            (List.map
                (\option ->
                    viewOption isToSelected
                        isToSelectable
                        option
                        model
                )
                copyPlaces
            )
        ]


isPanelSelectable : Model -> Bool
isPanelSelectable model =
    (model.sourcePanelIdx >= 0)
        && (model.sourcePanelIdx < List.length model.sourcePanels)


isFromSelected : CopyOption -> Model -> Bool
isFromSelected option model =
    model.copyFrom == option


isFromSelectable : CopyOption -> Model -> Bool
isFromSelectable option model =
    case option of
        Clipboard ->
            -- I don't know how to tell if the clipboard is empty
            True

        Live ->
            True

        Displayed ->
            True

        Panel ->
            isPanelSelectable model


isToSelected : CopyOption -> Model -> Bool
isToSelected option model =
    model.copyTo == option


isToSelectable : CopyOption -> Model -> Bool
isToSelectable option model =
    True


viewOption : (CopyOption -> Model -> Bool) -> (CopyOption -> Model -> Bool) -> CopyOption -> Model -> Html Msg
viewOption isSelected isSelectable copyOption model =
    let
        label =
            copyOptionLabel copyOption
    in
    option
        [ value label
        , selected <| isSelected copyOption model
        , disabled <| not (isSelectable copyOption model)
        ]
        [ text label ]


viewEditingSources : Model -> Html Msg
viewEditingSources model =
    span []
        [ button ToggleShowEditingSources <|
            if model.showEditingSources then
                "Hide editor"

            else
                "Show editor"
        , br
        , if not model.showEditingSources then
            text ""

          else
            span []
                [ viewSaveDeleteButtons model
                , viewEditingSourcesInternal model
                ]
        ]


th : String -> Html msg
th s =
    Html.th [] [ text s ]


td : String -> Html msg
td s =
    Html.td [] [ text s ]


caselessContains : String -> String -> Bool
caselessContains search string =
    String.contains (String.toLower search) <| String.toLower string


matchesSearchString : String -> Source -> Bool
matchesSearchString string { src, label, url } =
    let
        lab =
            case label of
                Nothing ->
                    getLabelFromFileName src

                Just l ->
                    l

        url2 =
            case url of
                Nothing ->
                    ""

                Just u ->
                    u
    in
    caselessContains string src
        || caselessContains string lab
        || caselessContains string url2


viewSearch : Int -> Int -> String -> List Source -> Html Msg
viewSearch searchStart searchCnt searchString sources =
    span []
        [ h3 "Search"
        , p []
            [ b "Search for: "
            , focusTrackingInput
                [ onInput InputSearchString
                , value searchString
                , width 20
                , style "min-width" "20em"
                ]
                [ text searchString ]
            ]
        , let
            matchedPairs =
                List.filter
                    (\( _, source ) -> matchesSearchString searchString source)
                    (List.indexedMap Tuple.pair sources)

            matchCnt =
                List.length matchedPairs

            panels =
                List.take searchCnt <| List.drop searchStart matchedPairs

            tableColumnCnt =
                4

            setSrc idx =
                SetSrcIdx <| String.fromInt idx

            showSource : ( Int, Source ) -> List (Html Msg)
            showSource ( idx, source ) =
                [ tr [ onClick <| setSrc idx ]
                    [ td <| String.fromInt idx
                    , Html.td [ style "text-align" "center" ]
                        [ viewSrc True
                            (computeImgSrc (Just source) idx |> Tuple.first)
                            "3em"
                            "4em"
                        ]
                    , td <| urlDisplay source.src
                    , td <|
                        case source.label of
                            Nothing ->
                                getLabelFromFileName source.src

                            Just lab ->
                                lab
                    ]
                , case source.url of
                    Nothing ->
                        text ""

                    Just url ->
                        tr [ onClick <| setSrc idx ]
                            [ Html.td [ colspan 2 ]
                                [ text special.nbsp ]
                            , Html.td [ colspan <| tableColumnCnt - 2 ]
                                [ b "url: "
                                , text url
                                ]
                            ]
                ]
          in
          p []
            [ table [ class "prettyTable" ] <|
                List.concat
                    [ [ tr []
                            [ th "idx"
                            , th "image"
                            , th "src"
                            , th "label"
                            ]
                      ]
                    , List.map showSource panels |> List.concat
                    , [ tr
                            [ style "align" "left" ]
                            [ let
                                cntDelta =
                                    if searchStart == 0 then
                                        0

                                    else
                                        1
                              in
                              Html.td [ colspan tableColumnCnt ]
                                [ enabledButton
                                    (searchStart < (matchCnt - searchCnt))
                                    (ScrollSearch True matchCnt)
                                    "v"
                                , enabledButton
                                    (searchStart > 0)
                                    (ScrollSearch False matchCnt)
                                    "^"
                                , enabledButton
                                    (searchCnt < matchCnt)
                                    (SearchMore True matchCnt)
                                    "More"
                                , text " "
                                , enabledButton (searchCnt > 10)
                                    (SearchMore False matchCnt)
                                    "Less"
                                , text " (showing "
                                , if searchStart > 0 then
                                    span []
                                        [ text <| String.fromInt searchStart
                                        , text "-"
                                        ]

                                  else
                                    text ""
                                , text <|
                                    String.fromInt <|
                                        min (searchStart + searchCnt - cntDelta)
                                            matchCnt
                                , text " of "
                                , text <| String.fromInt matchCnt
                                , text " matches)"
                                ]
                            ]
                      ]
                    ]
            ]
        ]


viewSourcePanels : Model -> Html Msg
viewSourcePanels model =
    span []
        [ h3 "Film Rolls"
        , p []
            [ p [] [ button (AddSourcePanel True) "Add" ]
            , p []
                [ table [ class "prettyTable" ] <|
                    List.indexedMap
                        (\idx panel ->
                            viewSourcePanel model idx panel
                        )
                        model.sourcePanels
                ]
            ]
        ]


viewSourcePanel : Model -> Int -> SourcePanel -> Html Msg
viewSourcePanel model idx panel =
    let
        sources =
            panel.panels

        isEditing =
            idx == model.sourcePanelIdx
    in
    tr []
        [ if not isEditing then
            Html.th [ onClick <| SelectSourcePanel idx ]
                [ text panel.name ]

          else
            let
                isFirst =
                    model.sourcePanelIdx == 0

                isLast =
                    model.sourcePanelIdx == List.length model.sourcePanels - 1
            in
            Html.th [ style "text-align" "left" ]
                [ focusTrackingInput
                    [ onInput InputEditingPanelName
                    , value panel.name
                    , style "width" "100%"
                    , style "min-height" "1em"
                    , style "min-width" "10em"
                    , Attributes.id ids.sourcePanelName
                    ]
                    [ text panel.name ]
                , br
                , enabledButton (not isFirst) (MoveSourcePanelUp True) "^"
                , text " "
                , button (SaveRestoreSourcePanel True) "Install"
                , text " "
                , button (SaveRestoreSourcePanel False) "Set"
                , br
                , enabledButton (not isLast) (MoveSourcePanelUp False) "v"
                , text " "
                , button (AddSourcePanel False) "Add"
                , text " "
                , button DeleteSourcePanel "Delete"
                ]
        , Html.td [ onClick <| SelectSourcePanel idx ] <|
            let
                sourcesCnt =
                    List.length sources

                nameCnt =
                    2

                names =
                    List.take nameCnt sources |> List.map .src |> List.intersperse ", "
            in
            List.concat
                [ [ text "("
                  , text <| String.fromInt sourcesCnt
                  , text ") "
                  ]
                , List.map text names
                , [ if nameCnt < sourcesCnt then
                        text ", ..."

                    else
                        text ""
                  ]
                ]
        ]


em : String -> Html msg
em string =
    Html.em [] [ text string ]


viewHelp : Html msg
viewHelp =
    span []
        [ p []
            [ text "Text boxes above are: "
            , em "index"
            , text ", "
            , em "display"
            , text ", "
            , em "label"
            , text ", "
            , em "url."
            , br
            , em "display"
            , text " is a URL or a builtin image path."
            , br
            , em "label"
            , text " allows you to override the file name default."
            , br
            , em "url"
            , text " allows you to open a different page than the "
            , em "display"
            , text " image on click."
            , br
            , text "Modify "
            , em "index"
            , text ", and click Move or Lookup button"
            , br
            , text "Modify "
            , em "display"
            , text ", "
            , em "label"
            , text ", or "
            , em "url"
            , text ", and click Change button."
            , br
            , text "Change all (or none) and click Add button."
            , br
            , text "Paste is Add plus copy clipboard to "
            , em "index"
            , text "."
            , br
            , text "Add and Paste add to end if "
            , em "index"
            , text " is out of range or not an integer."
            ]
        , p []
            [ text "The Add button makes a new record after the index."
            , br
            , text "If the index is non-numeric, negative, "
            , text "or too large, adds to the end."
            , br
            , text "The Change button updates the record with your changes."
            , br
            , text "The Move button moves the current record to the changed index."
            , br
            , text "The Lookup button refreshes the editing fields from the index."
            , br
            , text "The Delete button deletes the record."
            ]
        ]


nothingIfBlank : String -> Maybe String
nothingIfBlank s =
    if s == "" then
        Nothing

    else
        Just s


viewEditingSourcesInternal : Model -> Html Msg
viewEditingSourcesInternal model =
    span []
        [ p []
            [ focusTrackingInput
                [ onInput InputEditingIdxStr
                , width 2
                , value model.editingIdxStr
                , style "max-width" "3em"
                ]
                [ text model.editingIdxStr ]
            , text " : "
            , focusTrackingInput
                [ onInput InputEditingSrc
                , width 30
                , value model.editingSrc
                , style "min-height" "1em"
                , style "min-width" "20em"
                ]
                [ text model.editingSrc ]
            , text " "
            , focusTrackingInput
                [ onInput InputEditingName
                , width 20
                , value model.editingLabel
                ]
                [ text model.editingLabel ]
            , text " "
            , focusTrackingInput
                [ onInput InputEditingUrl
                , width 20
                , value model.editingUrl
                ]
                [ text model.editingUrl ]
            , let
                source =
                    Maybe.withDefault (srcSource "") <|
                        LE.getAt model.editingIdx model.sources

                editingIdx =
                    Maybe.withDefault -1 <|
                        String.toInt model.editingIdxStr

                editingLabel =
                    if model.editingLabel == getLabelFromFileName source.src then
                        Nothing

                    else if model.editingLabel == "" then
                        Nothing

                    else
                        Just model.editingLabel

                editingUrl =
                    nothingIfBlank model.editingUrl

                editingIdxChanged =
                    (editingIdx /= model.editingIdx)
                        && (editingIdx /= -1)

                isCurrent =
                    isEditingCurrent model
              in
              p []
                [ button AddEditingSrc "Add"
                , text " "
                , enabledButton
                    (not isCurrent)
                    ChangeEditingSrc
                    "Change"
                , text " "
                , enabledButton (editingIdx /= model.editingIdx)
                    MoveEditingSrc
                    "Move"
                , text " "
                , enabledButton (editingIdx /= -1 && not isCurrent)
                    LookupEditingSrc
                    "Lookup"
                , text " "
                , enabledButton (not (editingIdxChanged || editingIdx == -1))
                    DeleteEditingSrc
                    "Delete"
                ]
            , showHelpButton model
            , if not model.showHelp then
                text ""

              else
                span []
                    [ viewHelp
                    , showHelpButton model
                    ]
            ]
        ]


titledButton : String -> Bool -> Msg -> String -> Html Msg
titledButton theTitle enabled msg label =
    Html.button
        [ onClick msg
        , disabled <| not enabled
        , title theTitle
        , style "border-radius" "9999px"
        , style "border-width" "1px"
        ]
        [ b label ]


enabledButton : Bool -> Msg -> String -> Html Msg
enabledButton =
    titledButton ""


button : Msg -> String -> Html Msg
button =
    enabledButton True


stringFromCode : Int -> String
stringFromCode code =
    String.fromList [ Char.fromCode code ]


special =
    { nbsp = stringFromCode 160 -- \u00A0
    , copyright = stringFromCode 169 -- \u00A9
    , biohazard = stringFromCode 9763 -- \u2623
    , black_star = stringFromCode 10036 -- \u2734
    , hourglass = stringFromCode 8987 -- \u231B
    , hourglass_flowing = stringFromCode 9203 -- \u23F3
    , checkmark = stringFromCode 10003 -- \u2713
    , middleDot = stringFromCode 183 -- \u00B7
    }


titledCheckBox : String -> Msg -> Bool -> String -> Html Msg
titledCheckBox theTitle msg isChecked label =
    span
        [ onClick msg
        , style "cursor" "default"
        , title theTitle
        , style "white-space" "nowrap"
        ]
        [ input
            [ type_ "checkbox"
            , checked isChecked
            ]
            []
        , b label
        ]


checkBox : Msg -> Bool -> String -> Html Msg
checkBox =
    titledCheckBox ""


b : String -> Html msg
b string =
    Html.b [] [ text string ]


br : Html msg
br =
    Html.br [] []


main : Program () Model Msg
main =
    Browser.application
        { init = \flags -> init
        , onUrlChange = OnUrlChange
        , onUrlRequest = OnUrlRequest
        , view = view
        , update = update
        , subscriptions = subscriptions
        }


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Events.onVisibilityChange SetVisible
        , Events.onKeyUp <| keyDecoder False
        , Time.every 100.0 ReceiveTime
        , PortFunnels.subscriptions Process model
        , Events.onKeyDown <| keyDecoder True
        , getSettings ReceiveSettings
        , clipboardContents ClipboardContents

        --, Events.onMouseDown mouseDownDecoder
        ]


keyDecoder : Bool -> Decoder Msg
keyDecoder keyDown =
    JD.field "key" JD.string
        |> JD.map (OnKeyPress keyDown)


mouseDownDecoder : Decoder Msg
mouseDownDecoder =
    JD.succeed MouseDown


{-| from `fotoJsonSettings` var in site/index.html
-}
type alias AppSettings =
    { title : String
    , showTitle : Bool
    , localStoragePrefix : String
    , githubUrl : Maybe String
    , copyright : Maybe CopyrightInfo
    }


type alias CopyrightInfo =
    { date : String
    , url : String
    , text : String
    }


{-| This is called to deliver the app settings from site/index.html
-}
port getSettings : (Maybe AppSettings -> msg) -> Sub msg


{-| Call this to select the contents of a text input element
-}
port selectElement : String -> Cmd msg



-- Clipboard support


port clipboardWrite : String -> Cmd msg


{-| arg ignored, use "".
Initiates a clipboard read. String delivered via `clipboardContents`
-}
port clipboardRead : String -> Cmd msg


port clipboardContents : (String -> msg) -> Sub msg
