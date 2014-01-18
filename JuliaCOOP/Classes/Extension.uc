class Extension extends Julia.Extension
 implements IInterested_GameEvent_PawnDied,
            Julia.InterestedInEventBroadcast,
            Julia.InterestedInInternalEventBroadcast,
            Julia.InterestedInMissionEnded;

/**
 * Copyright (c) 2014 Sergei Khoroshilov <kh.sergei@gmail.com>
 * 
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 * 
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 * 
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

import enum ObjectiveStatus from SwatGame.Objective;

/**
 * SWAT team color
 * @type string
 */
const COLOR_BLUE = "0000FF";

/**
 * Suspects color
 * @type string
 */
const COLOR_RED = "FF0000";

/**
 * List of players who have joined spec mode when they were still alive
 * @type array<class'Pawn'>
 */
var protected array<Pawn> Spectators;

/**
 * Indicate whether the Ten Seconds warning has been shown
 * @type bool
 */
var protected bool bMissionEndTenSecWarning;

/**
 * Indicate whether the One Minute warning has been shown
 * @type bool
 */
var protected bool bMissionEndOneMinWarning;

/**
 * Indicate whether mission has been been completed with or without completing its objectives
 * @type bool
 */
var protected bool bMissionCompleted;

/**
 * Time mission will be aborted (Level.TimeSeconds)
 * @type float
 */
var protected float MissionAbortTime;

/**
 * Time a mission will be forced to end if neither of all charcters or all evidenced have been reported/secured
 * Setting this property to zero disables this feature
 * @type int
 */
var config int MissionEndTime;

/**
 * Indicate whether spectators should be excluded from procedure score table
 * @type bool
 */
var config bool IgnoreSpectators;

/**
 * Check whether this is a COOP server
 * 
 * @return  void
 */
public function BeginPlay()
{
    Super.BeginPlay();

    if (!self.Core.GetServer().IsCOOP())
    {
        log(self $ " refused to operate on a non-COOP server");
        self.Destroy();
        return;
    }

    SwatGameInfo(Level.Game).GameEvents.PawnDied.Register(self);

    self.Core.RegisterInterestedInEventBroadcast(self);
    self.Core.RegisterInterestedInInternalEventBroadcast(self);
    self.Core.RegisterInterestedInMissionEnded(self);
}

event Timer()
{
    if (self.MissionEndTime > 0)
    {
        self.CheckMissionAbortTime();
    }
}

/**
 * Attempt to add a player who has just joined spectator mode
 * 
 * @param   class'Pawn' Pawn
 * @param   class'Actor' Killer
 * @param   bool WasAThreat
 * @return  void
 */
public function OnPawnDied(Pawn Pawn, Actor Killer, bool WasAThreat)
{
    if (!Pawn.IsA('SwatPlayer') || !self.IgnoreSpectators || !class'Julia.Utils'.static.IsAMEnabled(Level))
    {
        return;
    }

    if (class'Extension'.static.IsSpectatorName(Pawn.GetHumanReadableName()))
    {
        self.AddSpectator(Pawn);
    }
}

/**
 * @see Julia.InterestedInEventBroadcast.OnEventBroadcast
 */
public function bool OnEventBroadcast(Player Player, Actor Sender, name Type, string Msg, optional PlayerController Receiver, optional bool bHidden)
{
    switch (Type)
    {
        case 'MissionCompleted' :
        case 'MissionFailed' :
            self.bMissionCompleted = true;
            break;
    }
    return true;
}

/**
 * Display incap/kill messages in chat
 * 
 * @see Julia.InterestedInInternalEventBroadcast.OnInternalEventBroadcast
 */
public function OnInternalEventBroadcast(name Type, optional string Msg, optional Julia.Player PlayerOne, optional Julia.Player PlayerTwo)
{
    local string Color, Message;

    // Overwrite for suspects
    Color = class'Extension'.const.COLOR_BLUE;

    switch (Type)
    {
        case 'EnemyHostageIncap' :
            Message = self.Locale.Translate("EventSuspectsIncapHostage");
            Color = class'Extension'.const.COLOR_RED;
            break;
        case 'EnemyHostageKill' :
            Message = self.Locale.Translate("EventSuspectsKillHostage");
            Color = class'Extension'.const.COLOR_RED;
            break;
        case 'EnemyPlayerKill' :
            Message = self.Locale.Translate("EventSuspectsIncapOfficer");
            Color = class'Extension'.const.COLOR_RED;
            break;
        case 'PlayerHostageIncap' :
            Message = self.Locale.Translate("EventSwatIncapHostage");
            break;
        case 'PlayerHostageKill' :
            Message = self.Locale.Translate("EventSwatKillHostage");
            break;
        case 'PlayerEnemyIncap' :
            Message = self.Locale.Translate("EventSwatIncapSuspect");
            break;
        case 'PlayerEnemyIncapInvalid' :
            Message = self.Locale.Translate("EventSwatIncapInvalidSuspect");
            break;
        case 'PlayerEnemyKill' :
            Message = self.Locale.Translate("EventSwatKillSuspect");
            break;
        case 'PlayerEnemyKillInvalid' :
            Message = self.Locale.Translate("EventSwatKillInvalidSuspect");
            break;
        default :
            return;
    }

    if (PlayerOne != None)
    {
        Message = class'Utils.StringUtils'.static.Format(Message, PlayerOne.GetName());
    }

    class'Utils.LevelUtils'.static.TellAll(Level, Message, Color);
}

/**
 * @see Julia.InterestedInMissionEnded.OnMissionEnded
 */
public function OnMissionEnded()
{
    if (self.IgnoreSpectators)
    {
        self.DeductSpectatorPoints();
    }
}

/**
 * Attempt to autocomplete the current mission if all of its objectives have been completed
 * 
 * @return  void
 */
protected function CheckMissionAbortTime()
{
    local int TimeRemaining;

    // The game is paused/ has been completed/ has not started yet
    if (self.Core.GetServer().GetGameState() != GAMESTATE_MidGame || !SwatRepo(Level.GetRepo()).AnyPlayersOnServer())
    {
        return;
    }

    // Timer is not active, attempt to activate it
    if (self.MissionAbortTime <= 0)
    {
        if (self.bMissionCompleted && self.AllObjectivesCompleted())
        {
            if (!self.AllProceduresCompleted())
            {
                log(self $ ": setting up mission abort timer");

                class'Utils.LevelUtils'.static.TellAll(
                    Level, self.Locale.Translate("MissionEndMessage", self.MissionEndTime/60, self.MissionEndTime),
                );
                self.MissionAbortTime = Level.TimeSeconds + self.MissionEndTime;
            }
            // Don't do the same check again
            self.bMissionCompleted = false;
        }
    }
    // All procedures have been completed, abort timer
    else if (self.AllProceduresCompleted())
    {
        log(self $ ": all procedures have been completed, aborting the timer");
        self.MissionAbortTime = 0;
    }
    // Time's up - abort game
    else if (self.MissionAbortTime <= Level.TimeSeconds)
    {
        log(self $ ": mission end time is up");
        SwatGameInfo(Level.Game).GameAbort();
        self.MissionAbortTime = 0;
    }
    // Attempt to display One Minute/Ten Seconds warnings
    else
    {
        TimeRemaining = int(self.MissionAbortTime - Level.TimeSeconds);

        if (TimeRemaining <= 10 && !self.bMissionEndTenSecWarning)
        {
            Level.Game.Broadcast(None, "", 'TenSecWarning');
            self.bMissionEndTenSecWarning = true;
        }
        else if (TimeRemaining <= 60 && !self.bMissionEndOneMinWarning)
        {
            Level.Game.Broadcast(None, "", 'OneMinWarning');
            self.bMissionEndOneMinWarning = true;
        }
    }
}

/**
 * Tell whether all COOP objectives have been completed
 * 
 * @return  bool
 */
protected function bool AllObjectivesCompleted()
{
    local int i;
    local ObjectiveStatus Status;
    local MissionObjectives Objectives;

    Objectives = SwatRepo(Level.GetRepo()).MissionObjectives;

    for (i = 0; i < Objectives.Objectives.Length; i++)
    {
        Status = SwatGameReplicationInfo(Level.Game.GameReplicationInfo).ObjectiveStatus[i];

        if (Objectives.Objectives[i].name == 'Automatic_DoNot_Die')
        {
            if (Status == ObjectiveStatus_Failed)
            {
                return false;
            }
        }
        else if (Status == ObjectiveStatus_InProgress)
        {
            return false;
        }
    }
    return true;
}

/**
 * Tell whether all procedures have been completed
 *
 * @return  bool
 */
protected function bool AllProceduresCompleted()
{
    return SwatRepo(Level.GetRepo()).Procedures.ProceduresMaxed();
}

/**
 * Attempt to deduct NoOfficersDown penalty points for players who have joined spectator mode
 * 
 * @return  void
 */
protected function DeductSpectatorPoints()
{
    local int i, j;
    local Procedures Procedures;
    local Procedure_NoOfficersDown Procedure;

    Procedures = SwatRepo(Level.GetRepo()).Procedures;

    for (i = 0; i < Procedures.Procedures.Length; i++)
    {
        if (Procedures.Procedures[i].class.name == 'Procedure_NoOfficersDown')
        {
            Procedure = Procedure_NoOfficersDown(Procedures.Procedures[i]);

            log(self $ ": number of DownedOfficers/Spectators - " $ Procedure.DownedOfficers.Length $ "/" $ self.Spectators.Length);

            while (self.Spectators.Length > 0)
            {
                for (j = 0; j < Procedure.DownedOfficers.Length; j++)
                {
                    if (Procedure.DownedOfficers[j] == SwatPawn(self.Spectators[0]))
                    {
                        log(self $ ": removing " $ self.Spectators[0] $ "/" $ SwatPawn(self.Spectators[0]) $ ") from DownedOfficers");
                        Procedure.DownedOfficers.Remove(j, 1);
                        break;
                    }
                }
                self.Spectators.Remove(0, 1);
            }
            break;
        }
    }
}

/**
 * Add a unique spectactor list Pawn entry
 * 
 * @param   class'Julia.Player' Player
 * @return  void
 */
protected function AddSpectator(Pawn Pawn)
{
    local int i;

    for (i = 0; i < self.Spectators.Length; i++)
    {
        if (self.Spectators[i] == Pawn)
        {
            return;
        }
    }
    log(self $ ": adding " $ Pawn $ " (" $ Pawn.GetHumanReadableName() $ ") to the spectator list");
    self.Spectators[self.Spectators.Length] = Pawn;
}

/**
 * Tell whether given name contains (SPEC) or (VIEW) suffix
 * 
 * @param   string Name
 * @return  bool
 */
static function bool IsSpectatorName(string Name)
{
    switch (Right(Name, 6))
    {
        case "(SPEC)":
        case "(VIEW)":
            return true;
    }
    return false;
}

event Destroyed()
{
    SwatGameInfo(Level.Game).GameEvents.PawnDied.UnRegister(self);

    if (self.Core != None)
    {
        self.Core.UnregisterInterestedInEventBroadcast(self);
        self.Core.UnregisterInterestedInInternalEventBroadcast(self);
        self.Core.UnregisterInterestedInMissionEnded(self);
    }

    while (self.Spectators.Length > 0)
    {
        self.Spectators[0] = None;
        self.Spectators.Remove(0, 1);
    }

    Super.Destroyed();
}

defaultproperties
{
    Title="Julia/COOP";
    Version="1.0.0";
    LocaleClass=class'Locale';
}

/* vim: set ft=java: */