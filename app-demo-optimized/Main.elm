module Main exposing (main)

import Browser
import Html exposing (..)
import Html.Attributes as HA exposing (style)
import Html.Events exposing (onClick, onInput)
import Html.Keyed as Keyed
import Markdown.ElmWithId
import Markdown.Option exposing (Option(..))
import Random
import Strings
import Style exposing (..)
import Tree exposing(Tree)
import ParseWithId
import Tree.Diff as Diff
import Process
import Task

{-|  This version of the demo app has some optimizations
that make the editing process smoother for long documents,
containing a lot of mathematics.

The idea is to to parse the document text when the
document is first opened.  The resulting parse
tree (AST: abstract syntax tree) is stored as
`model.lastAst`.  Each block in the AST carries
a label `(version, id): (Int, Int)`, where
the `id` is unique to each block.
Each time the text changes, a new AST is computed a
with an incremented version number.  The
the function function `Diff.mergeWith equals` is applied
to compute the updated AST.  The effect of this operation
is that the id's of the nodes that have not changed
are themselves unchanged.  In this way, MathJax will
not re-render mathematical text that is unchanged.

To see where these optimizations are applied,
look for the places where functions in the modules
`ParseWithId` and `Markdown.ElmWithId` are called.

-}
main : Program Flags Model Msg
main =
    Browser.element
        { view = view
        , update = update
        , init = init
        , subscriptions = subscriptions
        }


type alias Model =
    { sourceText : String
    , firstPart : String
    , secondPart : Maybe String
    , counter : Int
    , seed : Int
    , option : Option
    , firstAst : Tree ParseWithId.MDBlockWithId
    , lastAst : Tree ParseWithId.MDBlockWithId
    , renderedText : RenderedText Msg
    , docLoaded : Bool
    , message : String
    }

-- MSG

type Msg
    = Clear
    | GetContent String
    | GenerateSeed
    | NewSeed Int
    | RestoreText
    | RefreshText
    | SelectStandard
    | SelectExtended
    | SelectExtendedMath
    | GotSecondPart (RenderedText Msg)


type alias Flags =
    {}


--parseFirst : String -> String
--parseFirst doc =
--    String.left 12 doc
--
--parseSecond : String -> Cmd Msg
--parseSecond doc =
--    Process.sleep 10
--        |> Task.andThen (\_ -> Process.sleep 2000 |> Task.andThen (\_ -> Task.succeed (String.dropLeft 12 doc)))
--        |> Task.perform GotSecondPart

renderSecond : Model -> Cmd Msg
renderSecond model =
    Process.sleep 10
        |> Task.andThen (\_ -> Process.sleep 2000 |> Task.andThen (\_ -> Task.succeed (Markdown.ElmWithId.renderHtmlWithExternaTOC model.lastAst)))
        |> Task.perform GotSecondPart


getFirstPart : String -> String
getFirstPart str =
    String.left 500 str

init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        model =
            { sourceText = Strings.initialText
            , firstPart = String.left 400 Strings.initialText
            , secondPart = Nothing
            , counter = 1
            , seed = 0
            , option = ExtendedMath
            , firstAst =  Markdown.ElmWithId.parse -1 ExtendedMath (getFirstPart Strings.initialText)
            , lastAst = Markdown.ElmWithId.parse 0 ExtendedMath Strings.initialText
            , renderedText = Markdown.ElmWithId.renderHtmlWithExternaTOC <| Markdown.ElmWithId.parse -1 ExtendedMath (getFirstPart Strings.initialText)
            , docLoaded = False
            , message = "Starting up"
            }
    in
    ( model, renderSecond model )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.none


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GetContent str ->
            let
              newAst_ =  Markdown.ElmWithId.parse model.counter model.option str
              newAst = Diff.mergeWith ParseWithId.equal model.lastAst newAst_
            in
            ( { model
                | sourceText = str
                , counter = model.counter + 1
                , lastAst = newAst

              }
            , Cmd.none
            )

        GenerateSeed ->
            ( model, Random.generate NewSeed (Random.int 1 10000) )

        NewSeed newSeed ->
            ( { model | seed = newSeed }, Cmd.none )

        Clear ->
            ( { model
                | sourceText = ""
                , counter = model.counter + 1
              }
            , Cmd.none
            )

        RestoreText ->
            ( { model
                | counter = model.counter + 1
                , sourceText = Strings.initialText
              }
            , Cmd.none
            )

        RefreshText ->
            ( { model
                | counter = model.counter + 1
              }
            , Cmd.none
            )

        SelectStandard ->
            ( { model
                | option = Standard
              }
            , Cmd.none
            )

        SelectExtended ->
            ( { model
                | option = Extended
              }
            , Cmd.none
            )

        SelectExtendedMath ->
            ( { model
                | option = ExtendedMath
              }
            , Cmd.none
            )

        GotSecondPart newRenderedText ->
            ({model | renderedText = newRenderedText, message = "Got second part"}, Cmd.none)

--
-- VIEW FUNCTIONS
---


view : Model -> Html Msg
view model =
    div outerStyle
        [ display model
        ]


type alias RenderedText msg = {title: Html msg, toc: Html msg, document: Html msg}

display : Model -> Html Msg
display model =
  let
     rt : RenderedText Msg
     rt = Markdown.ElmWithId.renderHtmlWithExternaTOC model.lastAst
  in
    div []
        [ h2 [ style "margin-left" "20px", style "margin-bottom" "0px", style "margin-top" "0px" ] [ text "Pure Elm Markdown Demo (Experimental)" ]
        , p [style "margin-left" "20px", style "margin-top" "0", style "font-size" "14pt"] [text "Now using MathJax 3"]
        , editor model
        , renderedSource rt model
        , p [ style "clear" "left", style "margin-left" "20px", style "margin-top" "-20px" ] [ clearButton 60, restoreTextButton 80, span [style "margin-left" "30px", style "margin-right" "10px" ] [text "Markdown flavor: "], standardMarkdownButton model 100, extendedMarkdownButton model 100, extendedMathMarkdownButton model 140  ]
        , a [ HA.href "https://minilatex.io", style "clear" "left", style "margin-left" "20px", style "margin-top" "0px" ] [ text "minilatex.io" ]
        , a [ HA.href "https://package.elm-lang.org/packages/jxxcarlson/elm-markdown/latest/", style "clear" "left", style "margin-left" "20px", style "margin-top" "0px" ] [ text "package.elm-lang.org" ]
        , p [] [text model.message]
        ]


label text_ =
    p labelStyle [ text text_ ]


editor : Model -> Html Msg
editor model =
    textarea (editorTextStyle ++ [ onInput GetContent, HA.value model.sourceText ]) []


renderedSource : RenderedText Msg -> Model -> Html Msg
renderedSource rt model =
    let
        token =
            String.fromInt model.counter
    in
      div [] [
         div  renderedSourceStyle [ h1 [style "font-size" "14px"] [rt.title],  rt.document  ]
       , div tocStyle [rt.toc]
      ]


renderedSource1 : RenderedText Msg -> Model -> Html Msg
renderedSource1 rt model =
    let
        token =
            String.fromInt model.counter
    in
      div [] [
        Keyed.node "div"  renderedSourceStyle [ (token ++ "-xx", h1 [style "font-size" "14px"] [ rt.title]), ( token, rt.document ) ]
       , div tocStyle [rt.toc]
      ]




-- BUTTONS --


clearButton width =
    button ([ onClick Clear ] ++ buttonStyle colorBlue width) [ text "Clear" ]


restoreTextButton width =
    button ([ onClick RestoreText ] ++ buttonStyle colorBlue width) [ text "Restore" ]


standardMarkdownButton model width =
    button ([ onClick SelectStandard ] ++ buttonStyleSelected (model.option == Standard) colorBlue colorDarkRed width) [ text "Standard" ]


extendedMarkdownButton model width =
    button ([ onClick SelectExtended ] ++ buttonStyleSelected (model.option == Extended) colorBlue colorDarkRed width) [ text "Extended" ]


extendedMathMarkdownButton model width =
    button ([ onClick SelectExtendedMath ] ++ buttonStyleSelected (model.option == ExtendedMath) colorBlue colorDarkRed width) [ text "Extended-Math" ]
