{-# OPTIONS_GHC -fno-warn-incomplete-patterns #-}
{-# LANGUAGE FlexibleContexts #-}

import Data.Maybe (fromJust)
import Data.Semigroup ((<>))
import System.Environment (getArgs)
import System.Exit (die, exitFailure)

import qualified Data.ByteString.Lazy as L
import Data.Aeson (decode, eitherDecode, encode)
import Data.Text.Strict.Lens (utf8)
import System.Posix.Files (getFileStatus, isDirectory)

import Control.Lens (preview, re, review, set, view)

import Crypto.JWT

import JWS (doJwsSign, doJwsVerify)
import KeyDB

main :: IO ()
main = do
  args <- getArgs
  case head args of
    "jwk-gen" -> doGen (tail args)
    "jws-sign" -> doJwsSign (tail args)
    "jws-verify" -> doJwsVerify (tail args)
    "jwt-sign" -> doJwtSign (tail args)
    "jwt-verify" -> doJwtVerify (tail args)
    "jwk-thumbprint" -> doThumbprint (tail args)

doGen :: [String] -> IO ()
doGen [kty] = do
  k <- genJWK $ case kty of
                  "oct" -> OctGenParam 32
                  "rsa" -> RSAGenParam 256
                  "ec" -> ECGenParam P_256
                  "eddsa" -> OKPGenParam Ed25519
  let
    h = view thumbprint k :: Digest SHA256
    kid' = view (re (base64url . digest) . utf8) h
    k' = set jwkKid (Just kid') k
  L.putStr (encode k')

-- | Mint a JWT.  Args are:
--
-- 1. filename of JWK
-- 2. filename of a claims object
--
-- Output is a signed JWT.
--
doJwtSign :: [String] -> IO ()
doJwtSign [jwkFilename, claimsFilename] = do
  Just k <- decode <$> L.readFile jwkFilename
  Just claims <- decode <$> L.readFile claimsFilename
  result <- runJOSE $ makeJWSHeader k >>= \h -> signClaims k h claims
  case result of
    Left e -> print (e :: Error) >> exitFailure
    Right jwt -> L.putStr (encodeCompact jwt)


-- | Validate a JWT.  Args are:
--
-- 1. filename of JWK
-- 2. filename of a JWT
-- 3. audience
--
-- Extraneous trailing args are ignored.
--
-- If JWT is valid, output JSON claims and exit 0,
-- otherwise exit nonzero.
--
doJwtVerify :: [String] -> IO ()
doJwtVerify [jwkFilename, jwtFilename, aud] = do
  jwtData <- L.readFile jwtFilename
  let
    aud' = fromJust $ preview stringOrUri aud
    conf = defaultJWTValidationSettings (== aud')
    go k = runJOSE $ decodeCompact jwtData >>= verifyClaims conf k

  jwkDir <- isDirectory <$> getFileStatus jwkFilename
  result <-
    if jwkDir
    then go (KeyDB jwkFilename)
    else (eitherDecode <$> L.readFile jwkFilename :: IO (Either String JWK))
      >>= rightOrDie "Failed to decode JWK"
      >>= go

  case result of
    Left e -> print (e :: JWTError) >> exitFailure
    Right claims -> L.putStr $ encode claims

rightOrDie :: (Show e) => String -> Either e a -> IO a
rightOrDie s = either (die . (\e -> s <> ": " <> show e)) pure


-- | Print a base64url-encoded SHA-256 JWK Thumbprint.  Args are:
--
-- 1. filename of JWK
--
doThumbprint :: [String] -> IO ()
doThumbprint (jwkFilename : _) = do
  Just k <- decode <$> L.readFile jwkFilename
  let h = view thumbprint k :: Digest SHA256
  L.putStr $ review (base64url . digest) h
