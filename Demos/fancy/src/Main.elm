module Main exposing (main)

-- for external copy-paste if needed

import Browser
import Browser.Dom as Dom
import Editor exposing (Editor, EditorConfig, EditorMsg)
import Editor.Config exposing (WrapOption(..))
import Editor.Update as E
import Html exposing (..)
import Html.Attributes as HA exposing (style)
import Html.Events exposing (onClick, onInput)
import Json.Encode as E
import Markdown.Option exposing (MarkdownOption(..), OutputOption(..))
import Markdown.Parse as Parse
import Markdown.Render exposing (MarkdownMsg(..), MarkdownOutput(..))
import Outside
import Process
import Random
import Strings
import Style
import Task exposing (Task)
import Tree exposing (Tree)
import Tree.Diff as Diff


{-| This version of the demo app has some optimizations
that make the editing process smoother for long documents,
containing a lot of mathematics.

The idea is to to parse the document text when the
document is first opened. The resulting parse
tree (AST: abstract syntax tree) is stored as
`model.lastAst`. Each block in the AST carries
a label `(version, id): (Int, Int)`, where
the `id` is unique to each block.
Each time the text changes, a new AST is computed a
with an incremented version number. The
function function `Diff.mergeWith equals` is applied
to compute the updated AST. The effect of this operation
is that the id's of the nodes that have not changed
are themselves unchanged. In this way, MathJax will
not re-render mathematical text that is unchanged.

To see where these optimizations are applied,
look for the places where functions in the modules
`Parse` and `Markdown.Render` are called.

-}
main : Program Flags Model Msg
main =
    Browser.element
        { view = view
        , update = update
        , init = init
        , subscriptions = subscriptions
        }



-- MODEL


type alias Model =
    { counter : Int
    , seed : Int
    , option : MarkdownOption
    , sourceText : String
    , lastAst : Tree Parse.MDBlockWithId
    , renderedText : MarkdownOutput
    , message : String
    , editor : Editor
    , clipboard : String
    , width : Float
    , height : Float
    , selectedId : ( Int, Int )
    }


highlightVerticalOffset : Float
highlightVerticalOffset =
    160


emptyAst : Tree Parse.MDBlockWithId
emptyAst =
    Parse.toMDBlockTree -1 ExtendedMath ""


emptyRenderedText : MarkdownOutput
emptyRenderedText =
    Markdown.Render.fromASTWithOptions (ExternalTOC "Contents") ( 0, 0 ) emptyAst



-- MSG


type Msg
    = NoOp
    | EditorMsg EditorMsg
    | Outside Outside.InfoForElm
    | LogErr String
    | Clear
    | Restart
    | GetContent String
    | ProcessLine String
    | SetViewPortForElement (Result Dom.Error ( Dom.Element, Dom.Viewport ))
    | GenerateSeed
    | NewSeed Int
    | LoadExample1
    | LoadExample2
    | SelectStandard
    | SelectExtended
    | SelectExtendedMath
    | GotSecondPart ( Tree Parse.MDBlockWithId, MarkdownOutput )
    | MarkdownMsg MarkdownMsg


type alias Flags =
    { width : Float
    , height : Float
    }


proportion =
    { width = 0.35
    , height = 0.7
    }


initialText =
    Strings.text1


init : Flags -> ( Model, Cmd Msg )
init flags =
    doInit flags


config : Flags -> EditorConfig Msg
config flags =
    { editorMsg = EditorMsg
    , width = flags.width * proportion.width
    , height = flags.height * proportion.height
    , lineHeight = 16.0
    , showInfoPanel = False
    , wrapParams = { maximumWidth = 45, optimalWidth = 40, stringWidth = String.length }
    , wrapOption = DontWrap
    , fontProportion = 0.75
    , lineHeightFactor = 1
    }


doInit : Flags -> ( Model, Cmd Msg )
doInit flags =
    let
        editor =
            Editor.init (config flags) initialText

        lastAst =
            Parse.toMDBlockTree 0 ExtendedMath (Editor.getSource editor)

        nMath =
            Markdown.Render.numberOfMathElements lastAst

        firstAst =
            if nMath > 10 then
                Parse.toMDBlockTree 1 ExtendedMath (getFirstPart initialText)

            else
                lastAst

        model =
            { counter = 2
            , seed = 0
            , option = ExtendedMath
            , sourceText = initialText
            , lastAst = lastAst
            , renderedText = Markdown.Render.fromASTWithOptions (ExternalTOC "Contents") ( 0, 0 ) firstAst
            , message = "Click ctrl-shift-I in editor to toggle info panel, ctrl-h to toggle help"
            , editor = editor
            , clipboard = ""
            , width = flags.width
            , height = flags.height
            , selectedId = ( 0, 0 )
            }
    in
    ( model, Cmd.batch [ resetViewportOfEditor, resetViewportOfRenderedText, renderSecond model ] )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        [ Outside.getInfo Outside LogErr
        ]



-- UPDATE


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        EditorMsg editorMsg ->
            let
                ( newEditor, editorCmd ) =
                    Editor.update editorMsg model.editor
            in
            case editorMsg of
                E.CopyPasteClipboard ->
                    syncWithEditor model newEditor editorCmd
                        |> (\( m, _ ) -> ( m, Outside.sendInfo (Outside.AskForClipBoard E.null) ))

                E.WriteToSystemClipBoard ->
                    ( { model | editor = newEditor }
                    , Cmd.batch
                        [ Outside.sendInfo (Outside.WriteToClipBoard (Editor.getSelectedText newEditor |> Maybe.withDefault "Nothing!!"))
                        , editorCmd |> Cmd.map EditorMsg
                        ]
                    )

                E.Insert str ->
                    updateEditor model newEditor editorCmd

                E.Unload str ->
                    syncWithEditor model newEditor editorCmd

                E.SendLine ->
                    syncAndHighlightRenderedText
                        (Editor.lineAtCursor newEditor)
                        (editorCmd |> Cmd.map EditorMsg)
                        { model | editor = newEditor }

                E.WrapAll ->
                    syncWithEditor model newEditor editorCmd

                E.Cut ->
                    syncWithEditor model newEditor editorCmd

                E.Paste ->
                    syncWithEditor model newEditor editorCmd

                E.Undo ->
                    syncWithEditor model newEditor editorCmd

                E.Redo ->
                    syncWithEditor model newEditor editorCmd

                E.RemoveGroupAfter ->
                    syncWithEditor model newEditor editorCmd

                E.RemoveGroupBefore ->
                    syncWithEditor model newEditor editorCmd

                E.Indent ->
                    syncWithEditor model newEditor editorCmd

                E.Deindent ->
                    syncWithEditor model newEditor editorCmd

                E.Clear ->
                    syncWithEditor model newEditor editorCmd

                E.WrapSelection ->
                    syncWithEditor model newEditor editorCmd

                _ ->
                    ( { model | editor = newEditor }, editorCmd |> Cmd.map EditorMsg )

        -- The below are optional, and used for external copy/pastes
        -- See module `Outside` and also `outside.js` and `index-katex.html` for additional
        -- information
        Outside infoForElm ->
            case infoForElm of
                Outside.GotClipboard clipboard ->
                    -- ( { model | clipboard = clipboard }, Cmd.none )
                    pasteToEditorClipboard model clipboard

        LogErr _ ->
            ( model, Cmd.none )

        GetContent str ->
            ( processContent str model, Cmd.none )

        ProcessLine str ->
            let
                id =
                    case Parse.searchAST str model.lastAst of
                        Nothing ->
                            "??"

                        Just id_ ->
                            id_ |> Parse.stringFromId
            in
            ( { model | message = "str = " ++ String.left 20 str ++ " -- Clicked on id: " ++ id }
            , setViewportForElement id
            )

        SetViewPortForElement result ->
            case result of
                Ok ( element, viewport ) ->
                    ( { model | message = "synced" }, setViewPortForSelectedLine element viewport )

                Err _ ->
                    ( { model | message = "sync error" }, Cmd.none )

        GenerateSeed ->
            ( model, Random.generate NewSeed (Random.int 1 10000) )

        NewSeed newSeed ->
            ( { model | seed = newSeed }, Cmd.none )

        NoOp ->
            ( model, Cmd.none )

        Clear ->
            load model ""

        Restart ->
            doInit (getFlags model)

        LoadExample1 ->
            load model Strings.text1

        LoadExample2 ->
            load model Strings.text2

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

        GotSecondPart ( newAst, newRenderedText ) ->
            ( { model | lastAst = newAst, renderedText = newRenderedText, counter = model.counter + 1 }, Cmd.none )

        MarkdownMsg markdownMsg ->
            case markdownMsg of
                IDClicked id ->
                    ( { model | message = "Clicked: " ++ id }, Cmd.none )



-- UPDATE HELPERS
-- updateRendered : Model -> ()


{-| Load text into Editor
-}
load : Model -> String -> ( Model, Cmd Msg )
load model text =
    let
        firstAst =
            Parse.toMDBlockTree model.counter ExtendedMath (getFirstPart text)

        newModel =
            { model
                | counter = model.counter + 1
                , message = "Loaded new text"
                , sourceText = text

                -- , firstAst =  firstAst
                , lastAst = Parse.toMDBlockTree model.counter ExtendedMath text
                , renderedText = Markdown.Render.fromASTWithOptions (ExternalTOC "Contents") ( 0, 0 ) firstAst
                , editor = Editor.init (config <| getFlags model) text
            }
    in
    ( newModel, Cmd.batch [ resetViewportOfRenderedText, resetViewportOfEditor, renderSecond newModel ] )


pasteToEditorClipboard : Model -> String -> ( Model, Cmd Msg )
pasteToEditorClipboard model str =
    let
        cursor =
            Editor.getCursor model.editor

        wrapOption =
            Editor.getWrapOption model.editor

        editor2 =
            Editor.placeInClipboard str model.editor
    in
    ( { model | editor = Editor.insert wrapOption cursor str editor2 }, Cmd.none )


syncWithEditor : Model -> Editor -> Cmd EditorMsg -> ( Model, Cmd Msg )
syncWithEditor model editor_ cmd_ =
    let
        text =
            Editor.getSource editor_

        ( newAst, renderedText ) =
            updateRenderingData model text
    in
    ( { model
        | editor = editor_
        , lastAst = newAst
        , renderedText = renderedText
        , counter = model.counter + 1
      }
    , Cmd.map EditorMsg cmd_
    )


updateEditor : Model -> Editor -> Cmd EditorMsg -> ( Model, Cmd Msg )
updateEditor model editor_ cmd_ =
    ( { model | editor = editor_ }, Cmd.map EditorMsg cmd_ )


updateRenderingData : Model -> String -> ( Tree Parse.MDBlockWithId, MarkdownOutput )
updateRenderingData model text_ =
    let
        newAst_ =
            Parse.toMDBlockTree model.counter model.option text_

        newAst__ =
            Diff.mergeWith Parse.equalContent model.lastAst newAst_

        renderedText__ : MarkdownOutput
        renderedText__ =
            Markdown.Render.fromASTWithOptions (ExternalTOC "Contents") ( 0, 0 ) newAst__
    in
    ( newAst__, renderedText__ )


{-| DOC sync LR
-}
syncAndHighlightRenderedText : String -> Cmd Msg -> Model -> ( Model, Cmd Msg )
syncAndHighlightRenderedText str cmd model =
    let
        targetId =
            Parse.searchAST str model.lastAst |> Maybe.withDefault ( 0, 0 )

        newAst =
            Parse.incrementVersion targetId model.lastAst

        ( i, v ) =
            targetId

        newId =
            ( i, v + 1 )

        newIdString =
            Parse.stringFromId newId

        renderedText =
            Markdown.Render.fromASTWithOptions (ExternalTOC "Contents") newId newAst
    in
    ( { model | renderedText = renderedText, lastAst = newAst, selectedId = newId }
    , Cmd.batch [ cmd, setViewportForElement newIdString ]
    )


{-| DOC sync LR
-}
processContentForHighlighting : String -> Model -> Model
processContentForHighlighting str model =
    let
        newAst_ =
            Parse.toMDBlockTree model.counter model.option str

        newAst =
            Diff.mergeWith Parse.equalIds model.lastAst newAst_
    in
    { model
        | sourceText = str

        -- rendering
        , lastAst = newAst
        , renderedText = Markdown.Render.fromASTWithOptions (ExternalTOC "Contents") model.selectedId newAst
        , counter = model.counter + 1
    }


processContent : String -> Model -> Model
processContent str model =
    let
        newAst_ =
            Parse.toMDBlockTree model.counter model.option str

        newAst =
            Diff.mergeWith Parse.equalContent model.lastAst newAst_
    in
    { model
        | sourceText = str

        -- rendering
        , lastAst = newAst
        , renderedText = Markdown.Render.fromASTWithOptions (ExternalTOC "Contents") model.selectedId newAst
        , counter = model.counter + 1
    }



-- VIEWPORT


resetViewportOfRenderedText : Cmd Msg
resetViewportOfRenderedText =
    Task.attempt (\_ -> NoOp) (Dom.setViewportOf "_rendered_text_" 0 0)


resetViewportOfEditor : Cmd Msg
resetViewportOfEditor =
    Task.attempt (\_ -> NoOp) (Dom.setViewportOf "_editor_" 0 0)



-- NEW STUFF


setViewportForElement : String -> Cmd Msg
setViewportForElement id =
    Dom.getViewportOf "_rendered_text_"
        |> Task.andThen (\vp -> getElementWithViewPort vp id)
        |> Task.attempt SetViewPortForElement


getElementWithViewPort : Dom.Viewport -> String -> Task Dom.Error ( Dom.Element, Dom.Viewport )
getElementWithViewPort vp id =
    Dom.getElement id
        |> Task.map (\el -> ( el, vp ))


setViewPortForSelectedLine : Dom.Element -> Dom.Viewport -> Cmd Msg
setViewPortForSelectedLine element viewport =
    let
        y =
            viewport.viewport.y + element.element.y - element.element.height - highlightVerticalOffset
    in
    Task.attempt (\_ -> NoOp) (Dom.setViewportOf "_rendered_text_" 0 y)



-- RENDERING


renderAstFor : Model -> String -> Cmd Msg
renderAstFor model text =
    let
        newAst =
            Parse.toMDBlockTree model.counter ExtendedMath text
    in
    Process.sleep 10
        |> Task.andThen
            (\_ ->
                Process.sleep 100
                    |> Task.andThen
                        (\_ -> Task.succeed ( newAst, Markdown.Render.fromASTWithOptions (ExternalTOC "Contents") model.selectedId newAst ))
            )
        |> Task.perform GotSecondPart


renderSecond : Model -> Cmd Msg
renderSecond model =
    renderAstFor model model.sourceText


getFirstPart : String -> String
getFirstPart str =
    String.left 1500 str



-- VIEW FUNCTIONS


view : Model -> Html Msg
view model =
    div [ HA.class "flex-column", style "width" (px model.width), style "margin-top" "18px" ]
        [ heading model
        , div [ HA.class "flex-row" ]
            [ embeddedEditor model
            , renderedSource model
            , tocView model
            ]
        , footer1 model
        , footer2 model
        ]


getFlags : Model -> Flags
getFlags model =
    { width = model.width, height = model.height }


transformFlagsForEditor : Flags -> Flags
transformFlagsForEditor flags =
    { flags | height = proportion.height * flags.height, width = proportion.width * flags.width }


heading : Model -> Html Msg
heading model =
    div [ HA.class "flex-row", style "height" "50px", style "margin-bottom" "8px", style "margin-top" "-16px" ]
        [ div [ style "width" "400px", style "margin-left" "48px", style "font-size" "14px" ] []
        , div [ style "width" "400px", style "margin-left" "-24px" ] [ titleView model ]
        , div [ style "width" "250px", style "margin-left" "48px" ] []
        ]


embeddedEditor : Model -> Html Msg
embeddedEditor model =
    let
        flags =
            transformFlagsForEditor <| getFlags model
    in
    div [ style "width" (px flags.width), style "overflow-x" "scroll", style "height" (px flags.height) ]
        [ Editor.embedded (config <| getFlags model) model.editor ]


px : Float -> String
px p =
    String.fromFloat p ++ "px"


titleView : Model -> Html Msg
titleView model =
    span [] [ Markdown.Render.title model.renderedText |> Html.map MarkdownMsg ]


renderedSource : Model -> Html Msg
renderedSource model =
    let
        flags =
            transformFlagsForEditor <| getFlags model
    in
    div
        [ HA.id "_rendered_text_"
        , style "width" (px flags.width)
        , style "height" (px flags.height)
        , style "margin-left" "24px"
        , style "padding-left" "12px"
        , style "padding-right" "12px"
        , style "overflow-x" "hidden "
        , style "overflow-y" "scroll"
        , style "background-color" "#fff"
        , style "border-style" "solid"
        , style "border-width" "thin"
        , style "border-color" "#999"
        ]
        [ Markdown.Render.document model.renderedText |> Html.map MarkdownMsg ]


tocView : Model -> Html Msg
tocView model =
    let
        h =
            (transformFlagsForEditor (getFlags model)).height - 23
    in
    div
        [ style "width" "250px"
        , style "height" (px h)
        , style "margin-left" "24px"
        , style "padding" "12px"
        , style "overflow" "scroll "

        -- , style "background-color" "#eee"
        ]
        [ Markdown.Render.toc model.renderedText |> Html.map MarkdownMsg ]


footer1 : Model -> Html Msg
footer1 model =
    p [ style "margin-left" "20px", style "margin-top" "0px" ]
        [ clearButton 60

        -- , restartButton 70
        , example1Button 80
        , example2Button 80
        , span [ style "margin-left" "30px", style "margin-right" "10px" ] [ text "Markdown flavor: " ]
        , standardMarkdownButton model 100
        , extendedMarkdownButton model 100
        , extendedMathMarkdownButton model 140
        ]


footer2 model =
    p []
        [ a [ HA.href "https://minilatex.io", style "clear" "left", style "margin-left" "20px", style "margin-top" "0px" ]
            [ text "minilatex.io" ]
        , a [ HA.href "https://package.elm-lang.org/packages/jxxcarlson/elm-markdown/latest/", style "clear" "left", style "margin-left" "20px", style "margin-top" "0px" ]
            [ text "jxxcarlson/elm-markdown" ]
        , a [ HA.href "https://package.elm-lang.org/packages/jxxcarlson/elm-text-editor/latest/", style "clear" "left", style "margin-left" "20px", style "margin-top" "0px" ]
            [ text "jxxcarlson/elm-text-editor" ]
        , messageLine model
        ]


messageLine : Model -> Html Msg
messageLine model =
    --let
    --    message =
    --        model.message
    --in
    --case String.contains "error" message of
    --    True ->
    --        span [ style "margin-left" "50px", style "color" "red" ] [ text <| model.message ]
    --
    --    False ->
    span [ style "margin-left" "50px" ] [ text <| model.message ]



-- BUTTONS --


clearButton width =
    button ([ onClick Clear ] ++ Style.buttonStyle Style.colorBlue width) [ text "Clear" ]


restartButton width =
    button ([ onClick Restart ] ++ Style.buttonStyle Style.colorBlue width) [ text "Restart" ]


example1Button width =
    button ([ onClick LoadExample1 ] ++ Style.buttonStyle Style.colorBlue width) [ text "Example 1" ]


example2Button width =
    button ([ onClick LoadExample2 ] ++ Style.buttonStyle Style.colorBlue width) [ text "Example 2" ]


standardMarkdownButton model width =
    button ([ onClick SelectStandard ] ++ Style.buttonStyleSelected (model.option == Standard) Style.colorBlue Style.colorDarkRed width) [ text "Standard" ]


extendedMarkdownButton model width =
    button ([ onClick SelectExtended ] ++ Style.buttonStyleSelected (model.option == Extended) Style.colorBlue Style.colorDarkRed width) [ text "Extended" ]


extendedMathMarkdownButton model width =
    button ([ onClick SelectExtendedMath ] ++ Style.buttonStyleSelected (model.option == ExtendedMath) Style.colorBlue Style.colorDarkRed width) [ text "Extended-Math" ]
