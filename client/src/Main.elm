port module Main exposing (main)

import Browser
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as Decode exposing (Decoder, Value)
import Json.Encode as Encode
import Browser.Dom as Dom
import Task
import Time exposing (Posix, Zone)
import Markdown.Parser
import Markdown.Renderer


port sendMessage : String -> Cmd msg
port changeUsername : String -> Cmd msg
port switchChannel : String -> Cmd msg
port newChannel : String -> Cmd msg
port removeChannel : String -> Cmd msg
port deleteMessage : Int -> Cmd msg
port removeFriend : String -> Cmd msg

port getMessage : (String -> msg) -> Sub msg
port changeStatus : (String -> msg) -> Sub msg

type alias Model = {
        inputMsg : String,
        msgs : List ChatMessage,
        status: String,
        statusClass: String,
        username : String,
        fingerprint : String,
        channels : List String,
        currentChannel : String,
        showNewChannel : Bool,
        zone : Zone,
        friends : List Friend
        }

type alias ChatMessage = {
        author : String,
        content : String,
        verified : Bool,
        fingerprint : String,
        timestamp: Posix,
        id: Int
        }

type alias History = {
        messages : List ChatMessage,
        name : String
        }

type alias RegisterAckMsg = {
        name : String,
        fingerprint : String
        }

type alias MessageEditMsg = {
        id : Int,
        content : String
        }

type alias Friend = {
        localName : Maybe String,
        fingerprint : String
        }

findFriend : String -> List Friend -> Maybe Friend
findFriend targetFingerprint friends =
        friends
        |> List.filter (\friend -> friend.fingerprint == targetFingerprint)
        |> List.head

type Msg
    = OnClick
    | OnInput String
    | MessageReceived ChatMessage
    | AckReceived String
    | StatusChanged String
    | HistoryUpdate History
    | Scrolled (Result Dom.Error ())
    | UsernameBlurred String
    | RegisterAck RegisterAckMsg
    | SystemMessage String
    | SwitchChannel String
    | ShowNewChannel
    | NewChannelBlurred String
    | FocusResult (Result Dom.Error ())
    | RemoveChannel String
    | OnMsgClick Int
    | MessageDeleted Int
    | RemoveFriend String
    | MessageEdited MessageEditMsg

onEnter : Msg -> Attribute Msg
onEnter msg =
    let
        keyDecoder =
                Decode.map2 Tuple.pair
                (Decode.field "key" Decode.string)
                (Decode.field "shiftKey" Decode.bool)
        checkEnter (key, shift) =
            if key == "Enter" && not shift then
                Decode.succeed ( msg, True )
            else
                Decode.fail "not enter"
    in
    preventDefaultOn "keydown" (keyDecoder 
    |> Decode.andThen checkEnter)

onEnterChannel : (String -> Msg) -> Attribute Msg
onEnterChannel msg =
    let
        keyDecoder = Decode.map2 Tuple.pair
                (Decode.field "key" Decode.string)
                (Decode.at ["target", "textContent"] Decode.string)
        checkEnter (key, textContent) =
            if key == "Enter" then
                Decode.succeed (msg textContent)
            else
                Decode.fail "not enter"
    in
    on "keydown" (keyDecoder 
    |> Decode.andThen checkEnter)

view : Model -> Html Msg
view model =
    div [ class "app-mount" ] [
            viewRail,
            viewSidebar model,
            viewChat model
    ]

viewRail : Html Msg
viewRail =
    aside [ class "rail" ] []

viewSidebar : Model -> Html Msg
viewSidebar model =
    aside [ class "sidebar" ] [
            h2 [ class "sidebar-title" ] [ text "Conversations" ],
            div [ class "sidebar-label" ] [ text "Channels" ],
            div [ class "channels" ] (
                    [viewChannel model.currentChannel "Global"] ++
                    List.map (viewChannel model.currentChannel) model.channels ++
                    [
                            if model.showNewChannel then
                                    div [
                                            class "channel new-channel",
                                            id "new-channel-input",
                                            onBlurWithContent NewChannelBlurred,
                                            onEnterChannel NewChannelBlurred,
                                            attribute "contenteditable" "true"
                                    ] [text ""]
                            else
                                    button [ class "new-channel-btn", onClick ShowNewChannel] [ text "Open" ]
                    ]

            ),
            if List.isEmpty model.friends then
                    text ""
            else
                    div [ class "sidebar-label" ] [ text "Friends" ],
                    div [ class "channels" ] (
                            List.map viewFriend model.friends
                    )
            ,
            div [ 
                    class "profile",
                    onBlurWithContent UsernameBlurred,
                    attribute "contenteditable" "true"
                ] [ text model.username ]
    ]

viewChannel : String -> String -> Html Msg
viewChannel current name = 
        div [class "channel-btn-container"] [
                button [ 
                        classList 
                        [
                                ("channel", True), 
                                ("current-channel", current == name)
                        ],
                        onClick (SwitchChannel name)
                ] [
                        div [ class "channel-name" ] [
                                span [ class "level open" ] [],
                                text name
                        ]
                ],
                div [ class "channel-controls" ] [
                        if name /= "Global" then
                                button [ class "remove", onClick (RemoveChannel name) ] [ text "[x]"]
                        else
                                text ""
                ]
        ]

viewChat : Model -> Html Msg
viewChat model =
    main_ [ class "chat" ] [ 
            viewHeader model.statusClass model.status model.currentChannel,
            viewMessages model.fingerprint model.zone model.friends model.msgs,
            viewControls model.inputMsg
        ]

viewHeader : String -> String -> String -> Html Msg
viewHeader statusClass status currentChannel =
        header [ class "chat-header" ] [
                h1 [] [ text currentChannel ],
                div [class statusClass] [text status]
        ] 

viewMessages : String -> Zone -> List Friend -> List ChatMessage -> Html Msg
viewMessages userFingerprint zone friends msgs =
        section [ class "messages", id "log" ]  
                (List.map (viewMessage userFingerprint zone friends) msgs)

viewMessage : String -> Zone -> List Friend -> ChatMessage -> Html Msg
viewMessage userFingerprint zone friends msg =
        let 
            authored = msg.fingerprint == userFingerprint
            friend = findFriend msg.fingerprint friends
        in
                Html.div [
                        classList 
                        [
                                ("message", True), 
                                ("authored", authored),
                                ("system", msg.fingerprint == "system")
                        ]
                ] [ 
                        div [ class "msg-data" ] [
                                case friend of
                                        Just _ ->
                                                div [ class "friend-badge" ] []
                                        Nothing ->
                                                text ""
                                ,
                                if authored then
                                        button [ class "inline-btn", onClick (OnMsgClick msg.id) ] [ text "x" ]
                                else
                                        text ""
                                ,
                                div [ class "msg-author" ] [
                                        case friend of
                                                Just f ->
                                                        case f.localName of
                                                                Just name ->
                                                                        text name
                                                                Nothing ->
                                                                        text msg.author
                                                Nothing ->
                                                    text msg.author
                                ],
                                div [ class "msg-date" ] [ text (formatDate zone msg.timestamp) ]

                        ],
                        viewMsgContent msg.content
                ]

formatDate : Zone -> Posix -> String
formatDate zone posix =
        let
                hour = Time.toHour zone posix |> String.fromInt |> String.padLeft 2 '0'
                minute = Time.toMinute zone posix |> String.fromInt |> String.padLeft 2 '0'
        in
                hour ++ ":" ++ minute
       
viewControls : String -> Html Msg
viewControls inputMsg =
        div [class "controls"] [
                textarea [ onEnter OnClick, 
                placeholder "Type a message...",
                value inputMsg,
                onInput OnInput ] [],
                button [ onClick OnClick] [ text "Send" ]
        ]

viewFriend : Friend -> Html Msg
viewFriend friend =
        div [class "friend"] [
                case friend.localName of
                        Just name ->
                            text name
                        Nothing ->
                            text "unknown"
                ,
                div [] [ text ("(" ++ friend.fingerprint ++ ")") ],
                button [onClick (RemoveFriend friend.fingerprint)] [text "del"]
        ]

onBlurWithContent : (String -> msg) -> Attribute msg
onBlurWithContent toMsg =
        on "blur"
                (Decode.map toMsg (Decode.at ["target", "textContent"] Decode.string))

viewMsgContent : String -> Html msg
viewMsgContent markdownInput =
        let
            renderedHtml =
                    markdownInput
                    |> Markdown.Parser.parse
                    |> Result.mapError (\errors -> 
                            errors 
                            |> List.map Markdown.Parser.deadEndToString 
                            |> String.join "\n"
                    )
                    |> Result.andThen (Markdown.Renderer.render Markdown.Renderer.defaultHtmlRenderer)
        in
        case renderedHtml of
                Ok elements ->
                        div [class "msg-content"] elements
                Err _ ->
                        div [class "msg-content"] [text ""]


scrollChat : Cmd Msg
scrollChat =
        Dom.getViewportOf "log"
        |> Task.map (.scene >> .height)
        |> Task.andThen (Dom.setViewportOf "log" 0)
        |> Task.attempt Scrolled

focus : String -> Cmd Msg
focus elementId =
    Dom.focus elementId
        |> Task.attempt FocusResult

update : Msg -> Model -> (Model, Cmd Msg)
update msg model =
        case msg of 
                OnInput newMsg -> 
                        ({ model | inputMsg = newMsg }, Cmd.none)
                OnClick ->
                        if String.isEmpty (String.trim model.inputMsg) then
                                (model, Cmd.none)
                        else
                                (
                                { model 
                                | inputMsg = ""
                                },
                                sendMessage model.inputMsg
                                )
                MessageReceived newMsg ->
                        ( 
                        { model | msgs = model.msgs ++ [ newMsg ] }, 
                        scrollChat
                        )
                AckReceived newMsg ->
                        ( 
                        { model | msgs = model.msgs ++ [ { author = model.username, content = newMsg, verified = True, fingerprint = model.fingerprint, timestamp = Time.millisToPosix 0, id = 0} ] }, 
                        scrollChat
                        )
                HistoryUpdate history ->
                        ( 
                        { model | msgs = model.msgs ++ history.messages,
                        username = history.name}, 
                        scrollChat
                        )
                StatusChanged status ->
                        (
                                { model | status = status,
                                statusClass = case status of
                                        "Connected" -> "status connected"
                                        "Disconnected" -> "status disconnected"
                                        _ -> "status"

                                },
                                Cmd.none
                        )
                Scrolled result ->
                        ( model, Cmd.none )
                UsernameBlurred newName -> 
                        if String.isEmpty (String.trim newName) || newName == model.username then
                                (model, Cmd.none)
                        else
                                ({ model | username = newName }, changeUsername newName)
                RegisterAck regAck ->
                        (
                                { model | username = regAck.name, fingerprint = regAck.fingerprint },
                                Cmd.none
                        )
                SystemMessage result ->
                        ( 
                        { model | msgs = model.msgs ++ [ { author = "System", content = result, verified = True, fingerprint = "system", timestamp = Time.millisToPosix -1, id = 0 } ] }, 
                        scrollChat
                        )
                SwitchChannel name ->
                        if String.isEmpty name || name == model.currentChannel then
                                (model, Cmd.none)
                        else
                                ( { model | msgs = [], currentChannel = name }, switchChannel name )
                ShowNewChannel ->
                        ( { model | showNewChannel = True }, focus "new-channel-input" )
                NewChannelBlurred name ->
                        if String.isEmpty name || name == model.currentChannel then
                                ( { model | showNewChannel = False }, Cmd.none)
                        else
                                ( { 
                                        model | showNewChannel = False,
                                        msgs = [],
                                        currentChannel = name,
                                        channels = if List.member name model.channels || name == "Global" then 
                                                model.channels
                                        else
                                                model.channels ++ [ name ]
                                }, 
                                if List.member name model.channels || name == "Global" then
                                        switchChannel name
                                else
                                        newChannel name 
                                )
                FocusResult result ->
                        ( model, Cmd.none )
                RemoveChannel name ->
                        ( { model | channels = List.filter (\item -> item /= name) model.channels }, removeChannel name )
                OnMsgClick id ->
                        ( model, deleteMessage id )
                MessageDeleted id ->
                        ( { model | msgs = List.filter (\item -> item.id /= id) model.msgs }, Cmd.none )
                RemoveFriend fingerprint ->
                        ( { model | friends = List.filter (\item -> item.fingerprint /= fingerprint) model.friends }, removeFriend fingerprint )
                MessageEdited editedMsg ->
                        ( {
                                model |
                                        msgs = List.map 
                                                (\item -> if editedMsg.id == item.id then
                                                        { item | content = editedMsg.content }
                                                else 
                                                        item
                                                ) model.msgs 
                        }, Cmd.none )

initialModel : Model
initialModel = {
        inputMsg = "",
        msgs = [],
        status = "Disconnected",
        statusClass = "status disconnected",
        username = "unknown",
        fingerprint = "",
        channels = [],
        currentChannel = "Global",
        showNewChannel = False,
        zone = Time.utc,
        friends = []
        }

type alias Flags =
    { 
            channels : List String,
            timezoneOffset : Int,
            friends : List Friend
    }

init: Flags -> (Model, Cmd Msg)
init  flags = 
        let 
                zone = Time.customZone flags.timezoneOffset []
        in
                ( {initialModel | channels = flags.channels, zone = zone, friends = flags.friends}, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
        Sub.batch [
        getMessage handleIncomingMsg,
        changeStatus StatusChanged
        ]

typeDecoder : Decoder String
typeDecoder =
        Decode.field "type" Decode.string

messageContentDecoder : Decoder String
messageContentDecoder =
        Decode.field "content" Decode.string

messageHelperDecoder : Decoder ChatMessage
messageHelperDecoder =
        Decode.map6 ChatMessage
                (Decode.field "author" Decode.string)
                (Decode.field "content" Decode.string)
                (Decode.field "verified" Decode.bool)
                (Decode.field "fingerprint" Decode.string)
                (Decode.field "timestamp" (Decode.map Time.millisToPosix Decode.int))
                (Decode.field "id" Decode.int)

historyDecoder : Decoder History
historyDecoder =
        Decode.map2 History
                (Decode.field "messages" (Decode.list messageHelperDecoder))
                (Decode.field "name" Decode.string)

ackDecoder : Decoder String
ackDecoder =
        Decode.field "content" Decode.string

registerAckDecoder : Decoder RegisterAckMsg
registerAckDecoder =
        Decode.map2 RegisterAckMsg
                (Decode.field "author" Decode.string)
                (Decode.field "fingerprint" Decode.string)

messageDeletionDecoder : Decoder Int
messageDeletionDecoder =
        Decode.field "id" Decode.int

messageEditDecoder : Decoder MessageEditMsg
messageEditDecoder =
        Decode.map2 MessageEditMsg
                (Decode.field "id" Decode.int)
                (Decode.field "content" Decode.string)

routeByMessageType : String -> String -> Msg
routeByMessageType msgType rawJson =
        case msgType of
                "message" -> case Decode.decodeString messageHelperDecoder rawJson of
                        Ok content -> MessageReceived content
                        Err _ -> SystemMessage "error" 
                "history" -> case Decode.decodeString historyDecoder rawJson of
                        Ok content -> HistoryUpdate content
                        Err _ -> SystemMessage "error" 
                "ack" -> case Decode.decodeString ackDecoder rawJson of
                        Ok content -> AckReceived content
                        Err _ -> SystemMessage "error" 
                "register_ack" -> case Decode.decodeString registerAckDecoder rawJson of
                        Ok content -> RegisterAck content
                        Err _ -> SystemMessage "error" 
                "deleted" -> case Decode.decodeString messageDeletionDecoder rawJson of
                        Ok id -> MessageDeleted id
                        Err _ -> SystemMessage "error" 
                "edited" -> case Decode.decodeString messageEditDecoder rawJson of
                        Ok content -> MessageEdited content
                        Err _ -> SystemMessage "error" 
                _ -> SystemMessage "error" 

handleIncomingMsg : String -> Msg
handleIncomingMsg rawJson =
    case Decode.decodeString typeDecoder rawJson of
        Ok msgType ->
                routeByMessageType msgType rawJson
        Err _ -> SystemMessage rawJson

main = Browser.element {
        init = init,
        view = view,
        update = update,
        subscriptions = subscriptions
        }
