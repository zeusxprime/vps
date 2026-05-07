# Gestor VPS

Menu modular para VPS instalado em pasta oculta.

## Instalação

```bash
unzip gestorvps_repo.zip 
cd gestorvps_repo
sudo bash install.sh
```

Depois abra com:

```bash
gestorvps
```

## Estrutura

```text
/opt/.gestorvps/
├── gestorvps.sh
└── scripts/
    ├── git.sh
    ├── aws.sh
    └── outro.sh
```

## Menus

Todos os menus principais e submenus dos scripts usam entrada automática com 2 dígitos:

```text
01, 02, 03 ... 10
00 para voltar/sair
```

Ao digitar os dois números, a opção executa automaticamente sem apertar Enter.

A ordem visual dos menus segue o padrão:

```text
01 a 05 no lado esquerdo
06 a 10 no lado direito
00 separado para voltar/sair
```


## Tokens Gitea

Ao criar um token pelo menu `Gerenciar Tokens > Novo Token [ALL]`, o script salva automaticamente o registro local em:

```text
/root/gitea-tokens.txt
```

Formato salvo:

```text
DATA | USUARIO | NOME_TOKEN | ESCOPO | TOKEN
```

O arquivo é criado com permissão `600`, pois contém token em texto puro.

## Correção v9

Entrada dos menus ajustada para 2 dígitos com suporte a Backspace/Delete e limpeza de buffer antes da leitura.
