module Main exposing (main)

import Browser
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)

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

update : Msg -> Model -> Model
update msg model =
        case msg of 
                OnInput newMsg -> 
                        { model | inputMsg = newMsg }
                OnClick ->
                        if String.isEmpty (String.trim model.inputMsg) then
                                model
                        else
                                { model 
                                | msgs = model.msgs ++ [ model.inputMsg ],
                                inputMsg = ""
                                }

initialModel : Model
initialModel = {
        inputMsg = "",
        msgs = []
        }

main = Browser.sandbox {
        init = initialModel,
        view = view,
        update = update
        }
