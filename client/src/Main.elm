port module Main exposing (main)

import Browser
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)

port sendMessage : String -> Cmd msg

type alias Model = {
        inputMsg : String,
        msgs : List String
        }

type Msg
    = OnClick
    | OnInput String

view : Model -> Html Msg
view model =
    div [ class "chat" ]
        [ h1 [] [ text "Chat" ]
        , p []
            [ 
                    text "Disconnected",
                    div [] 
                    (List.map (\msg -> Html.li [] [ text msg ]) model.msgs)
                    ,
                    input [ placeholder "Type a message...",
                    value model.inputMsg,
                    onInput OnInput ] [],
                    button [ onClick OnClick] [ text "Send" ]
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

initialModel : Model
initialModel = {
        inputMsg = "",
        msgs = []
        }

init: () -> (Model, Cmd Msg)
init _ = ( initialModel, Cmd.none )

main = Browser.element {
        init = init,
        view = view,
        update = update,
        subscriptions = \_ -> Sub.none
        }
