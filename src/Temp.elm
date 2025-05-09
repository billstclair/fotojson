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


module Temp exposing (title, url)

import Url exposing (Url)
import Url.Parser as Parser exposing (Parser)
import Url.Parser.Query as Query


titleParser : Query.Parser (Maybe String)
titleParser =
    Query.string "title"


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
    Url.fromString "http://localhost:8080/site/index.html?title=Froboz"
        |> Maybe.withDefault emptyUrl


title : Maybe String
title =
    Parser.parse (Parser.query titleParser) url
        |> Maybe.withDefault Nothing
