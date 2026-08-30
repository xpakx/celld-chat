port module Main exposing (main)

import Browser
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Json.Decode as Decode exposing (Decoder, Value)
import Json.Encode as Encode

port sendMessage : String -> Cmd msg
port getMessage : (String -> msg) -> Sub msg
port changeStatus : (String -> msg) -> Sub msg

type alias Model = {
        inputMsg : String,
        msgs : List String,
        status: String,
        statusClass: String
        }

type Msg
    = OnClick
    | OnInput String
    | MessageReceived String
    | StatusChanged String

view : Model -> Html Msg
view model =
    div [ class "chat" ]
        [ h1 [] [ text "Chat" ]
        , p []
            [ 
                    div [class model.statusClass] [text model.status],
                    div [id "log"] 
                    (List.map (\msg -> Html.div [] [ text msg ]) model.msgs)
                    ,
                    div [class "controls"] [
                            input [ placeholder "Type a message...",
                            value model.inputMsg,
                            onInput OnInput ] [],
                            button [ onClick OnClick] [ text "Send" ]
                    ]
            ]
        ]

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
                                | msgs = model.msgs ++ [ model.inputMsg ],
                                inputMsg = ""
                                },
                                sendMessage model.inputMsg
                                )
                MessageReceived newMsg ->
                        ( 
                        { model | msgs = model.msgs ++ [ newMsg ] }, 
                        Cmd.none
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

initialModel : Model
initialModel = {
        inputMsg = "",
        msgs = [],
        status = "Disconnected",
        statusClass = "status disconnected"
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
    typeDecoder
        |> Decode.andThen payloadDecoder

payloadDecoder : String -> Decoder String
payloadDecoder messageType =
    case messageType of
        "message" ->
            Decode.field "content" Decode.string
        "ack" ->
            Decode.field "content" Decode.string
        "history" ->
            Decode.field "messages" (Decode.list Decode.string)
            |> Decode.map (String.join ", ")
        _ ->
            Decode.succeed "not implemented"

handleIncomingMsg : String -> Msg
handleIncomingMsg rawJson =
    case Decode.decodeString messageContentDecoder rawJson of
        Ok stringValue ->
            MessageReceived stringValue
        Err _ ->
            MessageReceived rawJson

main = Browser.element {
        init = init,
        view = view,
        update = update,
        subscriptions = subscriptions
        }
