port module Main exposing (main)

import Browser
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as Decode exposing (Decoder, Value)
import Json.Encode as Encode
import Browser.Dom as Dom
import Task


port sendMessage : String -> Cmd msg
port changeUsername : String -> Cmd msg

port getMessage : (String -> msg) -> Sub msg
port changeStatus : (String -> msg) -> Sub msg

type alias Model = {
        inputMsg : String,
        msgs : List ChatMessage,
        status: String,
        statusClass: String,
        username : String,
        fingerprint : String
        }

type alias ChatMessage = {
        author : String,
        content : String,
        verified : Bool,
        fingerprint : String
        }

type alias History = {
        messages : List ChatMessage,
        name : String
        }

type alias RegisterAckMsg = {
        name : String,
        fingerprint : String
        }

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
            div [ class "channels" ] [
                    button [ class "channel" ] [
                            div [ class "channel-name" ] [
                                    span [ class "level open" ] [],
                                    text "Global"
                            ]
                    ]

            ],
            div [ 
                    class "profile",
                    onBlurWithContent UsernameBlurred,
                    attribute "contenteditable" "true"
                ] [ text model.username ]
    ]

viewChat : Model -> Html Msg
viewChat model =
    main_ [ class "chat" ] [ 
            viewHeader model.statusClass model.status,
            viewMessages model.fingerprint model.msgs,
            viewControls model.inputMsg
        ]

viewHeader : String -> String -> Html Msg
viewHeader statusClass status =
        header [ class "chat-header" ] [
                h1 [] [ text "Chat" ],
                div [class statusClass] [text status]
        ] 

viewMessages : String -> List ChatMessage -> Html Msg
viewMessages userFingerprint msgs =
        section [ class "messages", id "log" ]  
                (List.map (viewMessage userFingerprint) msgs)

viewMessage : String -> ChatMessage -> Html Msg
viewMessage userFingerprint msg =
        Html.div [
                classList 
                [
                        ("message", True), 
                        ("authored", msg.fingerprint == userFingerprint)
                ] 
        ] [ 
                div [ class "msg-author" ] [ text msg.author ],
                div [ class "msg-content" ] [ text msg.content ]
        ]
       
viewControls : String -> Html Msg
viewControls inputMsg =
        div [class "controls"] [
                textarea [ onEnter OnClick, 
                placeholder "Type a message...",
                value inputMsg,
                onInput OnInput ] [],
                button [ onClick OnClick] [ text "Send" ]
        ]

onBlurWithContent : (String -> msg) -> Attribute msg
onBlurWithContent toMsg =
        on "blur"
                (Decode.map toMsg (Decode.at ["target", "textContent"] Decode.string))


scrollChat : Cmd Msg
scrollChat =
        Dom.getViewportOf "log"
        |> Task.map (.scene >> .height)
        |> Task.andThen (Dom.setViewportOf "log" 0)
        |> Task.attempt Scrolled


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
                        { model | msgs = model.msgs ++ [ { author = model.username, content = newMsg, verified = True, fingerprint = model.fingerprint } ] }, 
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
                        ( model, Cmd.none )

initialModel : Model
initialModel = {
        inputMsg = "",
        msgs = [],
        status = "Disconnected",
        statusClass = "status disconnected",
        username = "unknown",
        fingerprint = ""
        }

init: () -> (Model, Cmd Msg)
init _ = ( initialModel, Cmd.none )

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
        Decode.map4 ChatMessage
                (Decode.field "author" Decode.string)
                (Decode.field "content" Decode.string)
                (Decode.field "verified" Decode.bool)
                (Decode.field "fingerprint" Decode.string)

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
