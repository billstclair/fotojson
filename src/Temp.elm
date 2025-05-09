----------------------------------------------------------------------
--
-- I'm not managing to parse the query parameters from a URL.
-- I think I somehow need to accept and skip up to the query, but
-- I don't know how.
--
-- The code below gets what I expect for `url`, but `title` is `Nothing`.
-- I want it to be `Just "Froboz"`.
--
----------------------------------------------------------------------


module Temp exposing (film, title, url)

import Json.Decode as JD exposing (Decoder)
import Json.Decode.Pipeline as DP exposing (custom, hardcoded, optional, required)
import Json.Encode as JE exposing (Value)
import String.Extra as SE
import Url exposing (Url)
import Url.Parser as Parser exposing ((<?>), Parser)
import Url.Parser.Query as Query


emptyUrl : Url
emptyUrl =
    { protocol = Url.Http
    , host = ""
    , port_ = Nothing
    , path = "/"
    , query = Nothing
    , fragment = Nothing
    }


url : Url
url =
    Url.fromString "http://localhost:8080/site/index.html?title=Froboz&film=[\"foo\",\"bar\",\"https://etwof.com/gab/foo.jpg\"]"
        |> Maybe.withDefault emptyUrl


titleParser : Query.Parser (Maybe String)
titleParser =
    Query.string "title"


type alias Source =
    { src : String
    , label : Maybe String
    , url : Maybe String
    }


nothingIfBlank : String -> Maybe String
nothingIfBlank s =
    if s == "" then
        Nothing

    else
        Just s


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


sourcesDecoder : Decoder (List Source)
sourcesDecoder =
    JD.list sourceDecoder


imagePrefix : String
imagePrefix =
    "images/"


peoplePrefix : String
peoplePrefix =
    "people/"


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


urlDisplay : String -> String
urlDisplay theUrl =
    if String.startsWith "http" theUrl then
        let
            cnt =
                if String.startsWith "https://" theUrl then
                    8

                else
                    0
        in
        String.dropLeft cnt theUrl

    else if String.startsWith peoplePrefix theUrl then
        String.dropLeft (String.length peoplePrefix) theUrl

    else
        theUrl


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

                Just u ->
                    nothingIfBlank u
    in
    if source.src == src && source.label == maybeLabel && source.url == maybeUrl then
        source

    else
        { source
            | src = src
            , label = maybeLabel
            , url = maybeUrl
        }


srcSource : String -> Source
srcSource src =
    { src = urlDisplay src, label = Nothing, url = Nothing }


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


filmParser : Query.Parser (Maybe (List Source))
filmParser =
    Query.custom "film" maybeParseSourcesList


title : Maybe String
title =
    Parser.parse (Parser.top <?> titleParser) { url | path = "/" }
        |> Maybe.withDefault Nothing


film : Maybe (List Source)
film =
    Parser.parse (Parser.top <?> filmParser) { url | path = "/" }
        |> Maybe.withDefault Nothing
