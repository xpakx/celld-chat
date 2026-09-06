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
port getMessage : (String -> msg) -> Sub msg
port changeStatus : (String -> msg) -> Sub msg

type alias Model = {
        inputMsg : String,
        msgs : List ChatMessage,
        status: String,
        statusClass: String,
        username : String
        }

type alias ChatMessage = {
        author : String,
        content : String
        }

type alias History = {
        messages : List ChatMessage,
        name : String
        }

type Msg
    = OnClick
    | OnInput String
    | MessageReceived ChatMessage
    | AckReceived String
    | StatusChanged String
    | HistoryUpdate History
    | Scrolled (Result Dom.Error ())


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
            viewSidebar,
            viewChat model
    ]

viewRail : Html Msg
viewRail =
    aside [ class "rail" ] []

viewSidebar : Html Msg
viewSidebar =
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

            ]
    ]

viewChat : Model -> Html Msg
viewChat model =
    main_ [ class "chat" ] [ 
            viewHeader model.statusClass model.status model.username,
            viewMessages model.msgs,
            viewControls model.inputMsg
        ]

viewHeader : String -> String -> String -> Html Msg
viewHeader statusClass status username =
        header [ class "chat-header" ] [
                h1 [] [ text "Chat" ],
                div [class statusClass] [text (status ++ "  (" ++ username ++ ")")]
        ] 

viewMessages : List ChatMessage -> Html Msg
viewMessages msgs =
        section [ class "messages", id "log" ]  
                (List.map (\msg -> Html.div [class "message"] [
                        div [class "msg-author"] [text msg.author],
                        div [class "msg-content"] [text msg.content]
                        ]) msgs)
       

viewControls : String -> Html Msg
viewControls inputMsg =
        div [class "controls"] [
                textarea [ onEnter OnClick, 
                placeholder "Type a message...",
                value inputMsg,
                onInput OnInput ] [],
                button [ onClick OnClick] [ text "Send" ]
        ]


scrollChat : Cmd Msg
scrollChat =
        Dom.getViewportOf "log"
        |> Task.andThen (\info -> Dom.setViewportOf "log" 0 info.scene.height)
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
                        { model | msgs = model.msgs ++ [ { author = model.username, content = newMsg } ] }, 
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

initialModel : Model
initialModel = {
        inputMsg = "",
        msgs = [],
        status = "Disconnected",
        statusClass = "status disconnected",
        username = "unknown"
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
        Decode.map2 ChatMessage
                (Decode.field "author" Decode.string)
                (Decode.field "content" Decode.string)

historyDecoder : Decoder History
historyDecoder =
        Decode.map2 History
                (Decode.field "messages" (Decode.list messageHelperDecoder))
                (Decode.field "name" Decode.string)

ackDecoder : Decoder String
ackDecoder =
        Decode.field "content" Decode.string

routeByMessageType : String -> String -> Msg
routeByMessageType msgType rawJson =
        case msgType of
                "message" -> case Decode.decodeString messageHelperDecoder rawJson of
                        Ok content -> MessageReceived content
                        Err _ -> MessageReceived 
                                { author = "system", content = "error" }
                "history" -> case Decode.decodeString historyDecoder rawJson of
                        Ok content -> HistoryUpdate content
                        Err _ -> MessageReceived 
                                { author = "system", content = "error" }
                "ack" -> case Decode.decodeString ackDecoder rawJson of
                        Ok content -> AckReceived content
                        Err _ -> MessageReceived 
                                { author = "system", content = "error" }
                _ -> MessageReceived 
                        { author = "system", content = "error" }

handleIncomingMsg : String -> Msg
handleIncomingMsg rawJson =
    case Decode.decodeString typeDecoder rawJson of
        Ok msgType ->
                routeByMessageType msgType rawJson
        Err _ ->
                MessageReceived 
                        { author = "system", content = rawJson }

main = Browser.element {
        init = init,
        view = view,
        update = update,
        subscriptions = subscriptions
        }
