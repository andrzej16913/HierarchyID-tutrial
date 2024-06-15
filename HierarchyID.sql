-- Usuń tabelę Ranks jeśli istnieje
IF OBJECT_ID('dbo.Ranks') IS NOT NULL
  DROP TABLE dbo.Ranks

-- Stwórz tabelę Ranks, zawiera heirarchię stanowisk w firmie
-- RankID to identyfikator stanowiska
-- RankName to nazwa stanowiska
-- RankPos to HierarchyID zapisujący pozycję w firmie
CREATE TABLE dbo.Ranks(
    [RankID] [int] IDENTITY(1,1) NOT NULL,
    [RankName] [varchar](50) NOT NULL,
    [RankPos] [hierarchyid] NOT NULL
) ON [PRIMARY]
GO

-- Dodaje klucz główny do tabeli Ranks
ALTER TABLE [dbo].[Ranks]
    ADD CONSTRAINT PK_Ranks_RankID PRIMARY KEY NONCLUSTERED (RankID)
GO

-- Najprostzy sposób ustawiania pozycji,
-- to po prostu napisać string z hierarchią
INSERT INTO dbo.Ranks (RankName, RankPos)
VALUES
('CEO', '/'),
('Sales Manager', '/1/'),
('Production Manager', '/2/')

INSERT INTO dbo.Ranks (RankName, RankPos)
VALUES
('Sales consultant', '/1/1/'),
('Salesperson', '/1/2/')

-- Zobaczmy jak wygląd teraz tabela Rank
-- HierarchyID zostaje wypisany jako wartość heksadecymalna zapisana na dysku
-- Aby go przeczytać należy użyć castowania lub metody ToString
-- Metoda GetLevel pokazuje głębokość w hierarchii
SELECT *, CAST(RankPos AS nvarchar(100)) AS [RedablePosition],
RankPos.ToString() AS PositionString,
RankPos.GetLevel() AS LevelInHierarchy
FROM [dbo].[Ranks]

-- Zwróć uwagę, że poniższa linia wykonuje się bez błędu
-- Joker nie ma bezpośredniego przełożonego
-- Jeśli chcemy uniknąć takich sytuacji trzeba używać constraintów lub procedur
INSERT INTO dbo.Ranks (RankName, RankPos)
VALUES
('Joker', '/13/13/')

SELECT *, RankPos.ToString() AS PositionString 
FROM [dbo].[Ranks]

-- Metoda GetRoot() zwraca korzeń hierarchii
-- Zwróć uwagę, że GetRoot() nie jest wykonywane na rekordzie,
-- ale należy do typu
SELECT *, RankPos.ToString() AS PositionString 
FROM [dbo].[Ranks]
WHERE RankPos = hierarchyid::GetRoot()
GO

-- Usuń procedurę AddRank, jeśli istnieje
DROP PROC IF EXISTS AddRank
GO

-- Wstawianie nowych rekordów byłoby uciążliwe, gdyby ręczne podawanie hierarchii było zawsze konieczne
-- Ponadto łatwo wtedy o pomyłkę
-- Dlatego lepiej napisać procedurę, która zautomatyzuje proces
-- super_id to RankID stanowiska bezpośredniego przełożonego
-- rank_name to nazwa nowego stanowiska
CREATE PROC AddRank(@super_id int, @rank_name varchar(50)) AS
BEGIN
  -- super_node to pozycja przełożonego
  -- last_child to potomek, po którym będzie dodane nowe stanowisko
  DECLARE @super_node HIERARCHYID, @last_child HIERARCHYID

  -- Wczytanie pozycji przełożonego
  SELECT @super_node = RankPos
  FROM [dbo].[Ranks]
  WHERE RankID = @super_id

  -- Zanim przeczytany zostanie hierarchyid potomka, 
  -- należy się zabezpieczyć przed wyścigiem danych
  SET TRANSACTION ISOLATION LEVEL SERIALIZABLE
  BEGIN TRANSACTION
    -- Wczytanie pozycji ostatniego dziecka
    SELECT @last_child = max(RankPos)   
    FROM [dbo].[Ranks]   
    WHERE RankPos.GetAncestor(1) = @super_node;  

    -- Wstawienie nowego stanowiska
    INSERT [dbo].[Ranks] (RankPos, RankName)  
    VALUES (@super_node.GetDescendant(@last_child, NULL), @rank_name)  
  COMMIT 
END;
GO

-- Tutaj używamy procedury AddRank, żeby dodać stanowiska
EXEC AddRank 3, 'Factory Manager'
EXEC AddRank 7, 'Factory Specialist'
EXEC AddRank 7, 'Factory Engineer'
EXEC AddRank 9, 'Factory Assistant'
EXEC AddRank 3, 'Production Consultant'
GO

-- Zobaczmy jak teraz wygląda tabela
SELECT *, RankPos.ToString() AS PositionString 
FROM [dbo].[Ranks]
ORDER BY RankPos
GO

DROP PROC IF EXISTS MoveTree
GO

-- Jedną z wad HierarchyID jest skomplikowane przenoszenie drzew
-- Procedura MoveTree() przenosi stanowisko do nowego przełożonego wraz z podwładnymi
-- old_super - indeks przenoszonego wierzchołka
-- new_super - indeks stanowiska, które jest nowym przełożonym
CREATE PROCEDURE MoveTree(@old_super int, @new_super int) AS
BEGIN
  -- Pozycje starego i nowego przełożonego jako hierarchyid
  DECLARE @pos_old hierarchyid, @pos_new hierarchyid
  SELECT @pos_old = RankPos FROM [dbo].[Ranks] WHERE RankID = @old_super;

  -- Ochrona przed wyścigami danych
  SET TRANSACTION ISOLATION LEVEL SERIALIZABLE
  BEGIN TRANSACTION
    -- Wczytanie pozycji nowego przełożonego
    SELECT @pos_new = RankPos FROM [dbo].[Ranks] WHERE RankID = @new_super;

    -- Znalezienie nowej pozycji wśród potomków nowego przełożonego
    SELECT @pos_new = @pos_new.GetDescendant(max(RankPos), NULL)
    FROM [dbo].[Ranks] WHERE RankPos.GetAncestor(1) = @pos_new ;

    -- Aktualizacja RankPos by uwzględniała nową hierarchię
    UPDATE [dbo].[Ranks]
    SET RankPos = RankPos.GetReparentedValue(@pos_old, @pos_new)
    WHERE RankPos.IsDescendantOf(@pos_old) = 1 ;

  COMMIT TRANSACTION;
END;
GO

-- Zobaczmy jak to wygląda w praktyce
-- Przenosimy Factory Manager (7) i jego podwładnych, bezpośrednio pod CEO (1)
EXEC MoveTree 7, 1
GO

SELECT *, RankPos.ToString() AS PositionString
FROM [dbo].[Ranks]
ORDER BY RankPos

-- Teraz odwracamy poprzednie wywołanie
EXEC MoveTree 7, 3
GO

SELECT *, RankPos.ToString() AS PositionString
FROM [dbo].[Ranks]
ORDER BY RankPos

-- Teraz zobaczymy jak zamienić HierarchyID w SQLową tabelę
-- oraz jak zmienić zwykłą tabelę hierarchi, tak by używała HierarchyID

IF OBJECT_ID('dbo.FlatRanks') IS NOT NULL
  DROP TABLE dbo.FlatRanks

-- Tabela FlatRanks zawira hierarchię jako klucz obvy
-- RankID to identyfikator stanowiska
-- SuperID to identyfikator przełożonego
SELECT RankID, RankName, (
  SELECT superior.RankID FROM [dbo].[Ranks] superior
  WHERE lower.RankPos.GetAncestor(1) = superior.RankPos
) AS SuperID
INTO [dbo].[FlatRanks]
FROM [dbo].[Ranks] lower;
GO

-- Zobaczmy jak wygląda nowa tabela
SELECT * FROM dbo.FlatRanks

-- Teraz z joinem, żeby zobaczyć przełożonych
SELECT   
  Superior.RankID AS SuperID, Superior.RankName AS SuperiorTitle,   
  Lower.RankID AS RankID, Lower.RankName AS LowerTitle
FROM dbo.FlatRanks AS Lower
LEFT JOIN dbo.FlatRanks AS Superior  
ON Lower.SuperID = Superior.RankID  
ORDER BY SuperID, RankID 

-- Usuwamy 'Jokera', żeby nie przeszkadzał w kolejnych operacjach
DELETE FROM dbo.FlatRanks
WHERE RankID = 6

-- Teraz utworzymy nową tabelę NewRanks, która ma kolumnę typu HierarchyID
-- i skopjujemy do niej dane z FlatRanks
IF OBJECT_ID('dbo.NewRanks') IS NOT NULL
  DROP TABLE dbo.NewRanks

CREATE TABLE dbo.NewRanks
(
  RankPos hierarchyid,
  RankID int,
  RankName nvarchar(50),
  SuperID int
CONSTRAINT PK_NewOrg_RankPos
  PRIMARY KEY CLUSTERED (RankPos)
);
GO

--  DROP TABLE #Links

-- Tymczasowa pomocnicza tabela Links
-- LowerID to id podwładnego
-- SuperID to id przełożonego
-- Num będzie wykorzystany podczas tworzenia HierarchyID
CREATE TABLE #Links
(
    LowerID int,
    SuperID int,
    Num int
);
GO

-- Poniższe polecenie przyśpiesza wykowanie poniższych poleceń
CREATE CLUSTERED INDEX tmpind ON #Links(SuperID, LowerID);
GO

-- Kopiowanie danych do tabeli Links, Num zawiera rosnące numery dla każdego SuperID
INSERT #Links(LowerID, SuperID, Num)
SELECT RankID, SuperID,
  ROW_NUMBER() OVER (PARTITION BY SuperID ORDER BY SuperID)
FROM dbo.FlatRanks
GO

-- Tabela Links wygląda teraz tak
SELECT * FROM #Links ORDER BY SuperID, Num
GO

-- Aby skopiować dane do tabeli NewRanks, należy użyć rekurencji
WITH paths(path, RankID)
AS (
-- Ta część zwraca korzeń hierarchii  
SELECT hierarchyid::GetRoot() AS RankPos, LowerID
FROM #Links AS L
WHERE SuperID IS NULL

UNION ALL
-- Ta część zwraca wszystkie pozostałe wartości  
SELECT
CAST(p.path.ToString() + CAST(L.Num AS varchar(30)) + '/' AS hierarchyid),
L.LowerID
FROM #Links AS L
JOIN paths AS p
   ON L.SuperID = P.RankID
)
INSERT dbo.NewRanks (RankPos, O.RankID, O.RankName, O.SuperID)
SELECT P.path, O.RankID, O.RankName, O.SuperID
FROM dbo.FlatRanks AS O
JOIN Paths AS P
   ON O.RankID = P.RankID
GO

-- Jak wygląda nowa tabela
SELECT RankPos.ToString() AS LogicalNode, *
FROM dbo.NewRanks
ORDER BY LogicalNode;
GO

-- Dzięki HierarchyID można łatwo znaleźć wszystkie rekordy,
-- które są potomkami określonego rodzica 
DECLARE @X HIERARCHYID = (SELECT RankPos
FROM NewRanks
WHERE RankName = 'Factory Manager')

SELECT *, RankPos.ToString()
FROM NewRanks
WHERE RankPos.IsDescendantOf(@X) = 1
GO
