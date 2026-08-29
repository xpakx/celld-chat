port module Main exposing (main)

import Browser
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)

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
        getMessage MessageReceived,
        changeStatus StatusChanged
        ]

main = Browser.element {
        init = init,
        view = view,
        update = update,
        subscriptions = subscriptions
        }
